-- ============================================================================
-- 033: マイページ(公開プロフィール)機能
-- 001〜032 の後に、SQL Editorで実行してください。
--
-- 背景:
--   ランキングやチャットから、他プレイヤーのユーザー名をクリックして
--   「マイページ」(所持ライバー数・クリアステージ数・コロシアム最高到達階・
--   称号・一言コメント・保有ライバー一覧)を閲覧できるようにする。
--   マイページ上の各ライバーを選択すると、そのライバーの詳細(ステータス・
--   装備・スキル構成・衣装、すべて閲覧専用)を確認できる。
--
--   sync_combat_power(011)と同じ考え方で、players/player_roster/
--   player_inventory/player_dungeon_progressという非公開データから、
--   保存のたびにこのマイグレーションのsync_public_profile関数が
--   公開用スナップショット(player_public_profileテーブル)へ必要な
--   情報だけを複製する。これにより非公開テーブルのRLSを緩めることなく
--   「他人に見せてよい範囲」だけを明示的に公開できる。反映は保存
--   タイミングに依存するため多少のラグは許容する(ランキングと同様)。
--
--   一言コメントは唯一「ユーザーが自由入力する公開テキスト」なので、
--   専用のset_profile_comment RPCで文字数を制限したうえで直接
--   player_public_profileに書き込む(sync_public_profileでは上書きしない)。
--   称号(title)列は将来の称号システム用に列だけ用意し、今回は
--   書き込み手段を用意しない(常にnull)。
--
--   マイページからの通報はsubmit_user_report(対象メッセージを介さない
--   通報)で行う。既存のchat_reportsテーブルをそのまま使い、
--   message_id=null・channel='profile'として記録する(admin.html側は
--   029のままの一覧・処理フローを流用しつつ、message_idがnullの場合の
--   表示だけ別途調整する)。
--
--   コロシアムの「最高到達階」は、挑戦権(colosseum_floor_right)が
--   敗北で1Fに戻ってしまうため、別途colosseum_best_floor列で
--   「これまでの最高到達」を非公開players側で記録しておく
--   (resolve_colosseum_battle(013)の勝利時処理に1行追加。それ以外は
--   013から不変)。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- players: コロシアム最高到達階(挑戦権とは別に、敗北で後退しない記録)
-- ----------------------------------------------------------------------------
alter table public.players
  add column if not exists colosseum_best_floor integer not null default 1;

create or replace function public.resolve_colosseum_battle(
  p_floor integer,
  p_damage_dealt integer,
  p_won boolean,
  p_new_snapshot jsonb default null,
  p_new_max_hp_pool integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_row public.colosseum_floors%rowtype;
  v_floor_right integer;
  v_last_challenge timestamptz;
  v_medals integer := 0;
  v_result jsonb;
  v_roster_top4_hp integer;
  v_max_hp_cap integer;
  v_damage integer;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.players where id = v_player_id and banned_at is not null) then
    raise exception 'account banned';
  end if;
  if p_floor < 1 or p_floor > 10 then
    raise exception 'invalid floor';
  end if;
  if p_damage_dealt < 0 then
    raise exception 'invalid damage';
  end if;

  select colosseum_floor_right, colosseum_last_challenge_at
    into v_floor_right, v_last_challenge
    from public.players where id = v_player_id;

  if p_floor > coalesce(v_floor_right, 1) then
    raise exception 'floor not yet unlocked';
  end if;

  if v_last_challenge is not null and now() - v_last_challenge < interval '500 seconds' then
    raise exception 'colosseum cooldown active';
  end if;

  select * into v_row from public.colosseum_floors where floor = p_floor for update;

  if p_won then
    select coalesce(sum(max_hp), 0) into v_roster_top4_hp
      from (
        select max_hp from public.player_roster
          where player_id = v_player_id and unlocked = true
          order by max_hp desc limit 4
      ) t;
    v_max_hp_cap := greatest(round(v_roster_top4_hp * 1.3), 40);
    if coalesce(p_new_max_hp_pool, 0) > v_max_hp_cap then
      raise exception 'reported max_hp_pool exceeds plausible bound';
    end if;

    v_medals := case when p_floor >= 10 then 50 else 1 end;

    insert into public.colosseum_floors (floor, holder_id, holder_name, snapshot, hp_pool, max_hp_pool, wins, updated_at)
    values (
      p_floor, v_player_id,
      (select name from public.players where id = v_player_id),
      coalesce(p_new_snapshot, '[]'::jsonb),
      coalesce(p_new_max_hp_pool, 0),
      coalesce(p_new_max_hp_pool, 0),
      0, now()
    )
    on conflict (floor) do update set
      holder_id = excluded.holder_id,
      holder_name = excluded.holder_name,
      snapshot = excluded.snapshot,
      hp_pool = excluded.hp_pool,
      max_hp_pool = excluded.max_hp_pool,
      wins = 0,
      updated_at = now();

    update public.players
      set colosseum_medals = colosseum_medals + v_medals,
          colosseum_floor_right = case when p_floor < 10 then p_floor + 1 else 10 end,
          colosseum_best_floor = greatest(colosseum_best_floor, case when p_floor < 10 then p_floor + 1 else 10 end),
          colosseum_last_challenge_at = now(),
          updated_at = now()
      where id = v_player_id;

  else
    if v_row.holder_id is not null then
      v_damage := least(p_damage_dealt, v_row.max_hp_pool);

      update public.colosseum_floors
        set hp_pool = greatest(0, hp_pool - v_damage),
            wins = wins + 1,
            updated_at = now()
        where floor = p_floor;

      v_medals := p_floor;
      if v_row.holder_id <> v_player_id then
        insert into public.colosseum_mailbox (player_id, medals)
        values (v_row.holder_id, v_medals)
        on conflict (player_id) do update set medals = public.colosseum_mailbox.medals + v_medals;
      else
        update public.players set colosseum_medals = colosseum_medals + v_medals where id = v_player_id;
      end if;
    end if;

    update public.players
      set colosseum_floor_right = case when p_floor > 1 then 1 else colosseum_floor_right end,
          colosseum_last_challenge_at = now(),
          updated_at = now()
      where id = v_player_id;
  end if;

  select jsonb_build_object('medals_gained', v_medals, 'won', p_won) into v_result;
  return v_result;
end;
$$;

grant execute on function public.resolve_colosseum_battle to authenticated;

-- ----------------------------------------------------------------------------
-- player_public_profile: 公開プロフィールのスナップショット
-- (閲覧は誰でも可、書き込みはsync_public_profile/set_profile_commentの
--  RPC経由のみ。直接のinsert/update権限はauthenticatedロールに与えない)
-- ----------------------------------------------------------------------------
create table if not exists public.player_public_profile (
  player_id uuid primary key references public.players(id) on delete cascade,
  player_name text not null,
  comment text,
  title text,
  character_count integer not null default 0,
  cleared_stage_count integer not null default 0,
  colosseum_best_floor integer not null default 1,
  party_size integer not null default 0,
  roster jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.player_public_profile enable row level security;

drop policy if exists "player_public_profile_select_all" on public.player_public_profile;
create policy "player_public_profile_select_all"
  on public.player_public_profile for select
  using (true);

grant select on public.player_public_profile to authenticated;

-- ----------------------------------------------------------------------------
-- sync_public_profile: 保存のたびに呼ばれる想定(save_full_state/
-- sync_combat_powerと同じタイミング)。comment/titleはここでは触らない。
-- ----------------------------------------------------------------------------
create or replace function public.sync_public_profile()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_player_name text;
  v_colosseum_best integer;
  v_party_size integer;
  v_character_count integer;
  v_cleared_count integer;
  v_roster jsonb;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select name, colosseum_best_floor, coalesce(jsonb_array_length(party), 0)
    into v_player_name, v_colosseum_best, v_party_size
    from public.players where id = v_player_id;
  if v_player_name is null then
    return; -- まだplayersテーブルに行が無ければ何もしない(sync_combat_powerと同じ割り切り)
  end if;

  select count(*) into v_character_count
    from public.player_roster where player_id = v_player_id and unlocked = true;

  select count(*) into v_cleared_count
    from public.player_dungeon_progress where player_id = v_player_id and cleared = true;

  select coalesce(jsonb_agg(jsonb_build_object(
      'liver_id', pr.liver_id,
      'job', pr.job,
      'job_progress', coalesce(pr.job_progress, '{}'::jsonb),
      'hp', pr.hp, 'max_hp', pr.max_hp, 'mp', pr.mp, 'max_mp', pr.max_mp,
      'costume', pr.costume,
      'unlocked_costumes', coalesce(pr.unlocked_costumes, '[]'::jsonb),
      'equipped_weapon', case when wi.id is null then null else jsonb_build_object(
        'id', wi.id, 'type', wi.item_type, 'name', wi.name, 'rarity', wi.rarity, 'rarityLabel', wi.rarity,
        'value', wi.value,
        'resist', case when wi.resist_element is not null
          then jsonb_build_object('element', wi.resist_element, 'value', wi.resist_value) else null end,
        'weaponType', wi.weapon_type, 'affix', wi.affix, 'enhanceLevel', wi.enhance_level
      ) end,
      'equipped_armor', case when ai.id is null then null else jsonb_build_object(
        'id', ai.id, 'type', ai.item_type, 'name', ai.name, 'rarity', ai.rarity, 'rarityLabel', ai.rarity,
        'value', ai.value,
        'resist', case when ai.resist_element is not null
          then jsonb_build_object('element', ai.resist_element, 'value', ai.resist_value) else null end,
        'weaponType', ai.weapon_type, 'affix', ai.affix, 'enhanceLevel', ai.enhance_level
      ) end
    ) order by pr.liver_id), '[]'::jsonb)
    into v_roster
  from public.player_roster pr
  left join public.player_inventory wi on wi.id = pr.equipped_weapon_id
  left join public.player_inventory ai on ai.id = pr.equipped_armor_id
  where pr.player_id = v_player_id and pr.unlocked = true;

  insert into public.player_public_profile
    (player_id, player_name, character_count, cleared_stage_count, colosseum_best_floor, party_size, roster, updated_at)
  values
    (v_player_id, v_player_name, v_character_count, v_cleared_count, coalesce(v_colosseum_best, 1), coalesce(v_party_size, 0), v_roster, now())
  on conflict (player_id) do update set
    player_name = excluded.player_name,
    character_count = excluded.character_count,
    cleared_stage_count = excluded.cleared_stage_count,
    colosseum_best_floor = excluded.colosseum_best_floor,
    party_size = excluded.party_size,
    roster = excluded.roster,
    updated_at = now();
end;
$$;

grant execute on function public.sync_public_profile to authenticated;

-- ----------------------------------------------------------------------------
-- set_profile_comment: 一言コメントの設定(本人のみ、最大60文字)
-- ----------------------------------------------------------------------------
create or replace function public.set_profile_comment(p_comment text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_player_name text;
  v_comment text;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.players where id = v_player_id and banned_at is not null) then
    raise exception 'account banned';
  end if;
  if exists (
    select 1 from public.players
      where id = v_player_id and penalty_until is not null and penalty_until > now()
  ) then
    raise exception 'account penalized';
  end if;

  v_comment := nullif(trim(coalesce(p_comment, '')), '');
  if v_comment is not null and length(v_comment) > 60 then
    raise exception 'comment too long';
  end if;

  select name into v_player_name from public.players where id = v_player_id;
  if v_player_name is null then
    raise exception 'player not found';
  end if;

  insert into public.player_public_profile (player_id, player_name, comment, updated_at)
  values (v_player_id, v_player_name, v_comment, now())
  on conflict (player_id) do update set
    comment = excluded.comment,
    updated_at = now();
end;
$$;

grant execute on function public.set_profile_comment to authenticated;

-- ----------------------------------------------------------------------------
-- submit_user_report: マイページからの通報(対象メッセージを介さない)。
-- 既存のchat_reportsをそのまま使い、message_id=null・channel='profile'で
-- 記録する。同じ相手への「未解決の通報」は1件までに制限する(連投防止。
-- 解決済みになれば、改めて通報し直すことは可能)。
-- ----------------------------------------------------------------------------
create unique index if not exists idx_chat_reports_reporter_target_profile_open
  on public.chat_reports (reporter_id, reported_player_id)
  where message_id is null and status = 'open';

create or replace function public.submit_user_report(
  p_reported_player_id uuid,
  p_reason_category text,
  p_reason_text text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reporter uuid := auth.uid();
  v_target_name text;
  v_comment text;
  v_report_id bigint;
begin
  if v_reporter is null then
    raise exception 'not authenticated';
  end if;
  if p_reason_category not in ('spam','harassment','inappropriate','impersonation','other') then
    raise exception 'invalid reason category';
  end if;
  if p_reported_player_id = v_reporter then
    raise exception 'cannot report yourself';
  end if;

  select player_name, comment into v_target_name, v_comment
    from public.player_public_profile where player_id = p_reported_player_id;
  if v_target_name is null then
    raise exception 'player not found';
  end if;

  if exists (
    select 1 from public.chat_reports
      where reporter_id = v_reporter and reported_player_id = p_reported_player_id
        and message_id is null and status = 'open'
  ) then
    raise exception 'already reported';
  end if;

  insert into public.chat_reports
    (reporter_id, reported_player_id, message_id, channel, reported_body, reported_player_name,
     reason_category, reason_text, channel_context, author_context)
  values
    (v_reporter, p_reported_player_id, null, 'profile', coalesce(v_comment, ''), v_target_name,
     p_reason_category, nullif(trim(coalesce(p_reason_text, '')), ''), '[]'::jsonb, '[]'::jsonb)
  returning id into v_report_id;

  return v_report_id;
end;
$$;

grant execute on function public.submit_user_report to authenticated;
