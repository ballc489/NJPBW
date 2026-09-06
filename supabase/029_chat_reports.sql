-- ============================================================================
-- 029: チャットの通報機能
-- 001〜028 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・通報はsubmit_chat_report(誰でも呼べる)で登録する。対象メッセージの
--     チャンネル内の前後5件(全体の文脈)と、対象投稿者自身の前後5件
--     (その人の文脈)をその場でスナップショットして通報レコードに
--     一緒に保存する。チャットの総件数に関わらず、常に「対象メッセージの
--     前後」という小さな範囲だけを取得するクエリなので、件数が増えても
--     重くならない(既存のidx_chat_messages_channel_created、今回追加する
--     idx_chat_messages_channel_player_createdで十分速い)。
--   ・通報の閲覧・処理はadmin.html側からis_admin()を通したRPC
--     (admin_resolve_report)経由でのみ行う。7つの処分は単一のp_actionで
--     選び、投稿削除は別軸のp_delete_message(true/false)で任意に組み合わせる。
--   ・警告はannouncementsテーブルを個人宛てにも使えるよう拡張する
--     (target_player_id列。nullなら従来通り全体公開、値があれば
--     その人にだけ見える)。既存の全体公開ポリシーはtarget_player_idが
--     nullの行だけに限定し、別途本人だけが見られるポリシーを追加する
--     (これをしないと個人宛ての警告が全員に見えてしまう)。
--   ・一時ペナルティ(penalty_until)は恒久BAN(banned_at)と同じ考え方で、
--     クライアント起動時のゲートに加えて、save_full_state・
--     sync_combat_power・マーケット関連の全RPCでもサーバー側で弾く
--     (クライアント側のゲートだけだと、BANチェック漏れと同じ抜け道に
--     なりうるため)。期限が過ぎれば自動的に解除される(遅延評価、
--     管理者による明示的な解除操作は不要)。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- players: 一時ペナルティ・警告回数
-- ----------------------------------------------------------------------------
alter table public.players
  add column if not exists penalty_until timestamptz,
  add column if not exists penalty_reason text,
  add column if not exists warning_count integer not null default 0;

-- ----------------------------------------------------------------------------
-- announcements: 個人宛て警告に対応(target_player_id)
-- ----------------------------------------------------------------------------
alter table public.announcements
  add column if not exists target_player_id uuid references public.players(id) on delete cascade;

drop policy if exists "announcements_select_published" on public.announcements;
create policy "announcements_select_published" on public.announcements
  for select using (published_at <= now() and target_player_id is null);

drop policy if exists "announcements_select_own_personal" on public.announcements;
create policy "announcements_select_own_personal" on public.announcements
  for select using (target_player_id = auth.uid());

-- ----------------------------------------------------------------------------
-- chat_messages: 通報の文脈スナップショット用インデックス
-- ----------------------------------------------------------------------------
create index if not exists idx_chat_messages_channel_player_created
  on public.chat_messages (channel, player_id, created_at);

-- ----------------------------------------------------------------------------
-- chat_reports: 通報テーブル(閲覧は管理者のみ、書き込みはRPC経由のみ)
-- ----------------------------------------------------------------------------
create table if not exists public.chat_reports (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references public.players(id) on delete cascade,
  reported_player_id uuid references public.players(id) on delete set null,
  message_id bigint references public.chat_messages(id) on delete set null,
  channel text not null,
  reported_body text not null,
  reported_player_name text not null,
  reason_category text not null check (reason_category in ('spam','harassment','inappropriate','impersonation','other')),
  reason_text text,
  channel_context jsonb not null default '[]'::jsonb,
  author_context jsonb not null default '[]'::jsonb,
  status text not null default 'open' check (status in ('open','resolved')),
  resolution_action text check (resolution_action in ('ban_reported','penalty_reported','warn_reported','warn_reporter','penalty_reporter','ban_reporter','close')),
  message_deleted boolean not null default false,
  resolved_by uuid references auth.users(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_chat_reports_status_created
  on public.chat_reports (status, created_at desc);
create unique index if not exists idx_chat_reports_reporter_message
  on public.chat_reports (reporter_id, message_id);

alter table public.chat_reports enable row level security;

drop policy if exists "chat_reports_select_admin" on public.chat_reports;
create policy "chat_reports_select_admin" on public.chat_reports
  for select using (public.is_admin());
-- 書き込みはsubmit_chat_report/admin_resolve_report(いずれもSECURITY DEFINER)
-- からのみ行うので、insert/update/delete用のポリシーは用意しない。

grant select on public.chat_reports to authenticated;

-- ----------------------------------------------------------------------------
-- submit_chat_report: 通報の登録(誰でも呼べる。管理者権限は不要)
-- ----------------------------------------------------------------------------
create or replace function public.submit_chat_report(
  p_message_id bigint,
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
  v_msg record;
  v_channel_context jsonb;
  v_author_context jsonb;
  v_report_id bigint;
begin
  if v_reporter is null then
    raise exception 'not authenticated';
  end if;
  if p_reason_category not in ('spam','harassment','inappropriate','impersonation','other') then
    raise exception 'invalid reason category';
  end if;

  select * into v_msg from public.chat_messages where id = p_message_id;
  if not found then
    raise exception 'message not found';
  end if;

  if v_msg.player_id = v_reporter then
    raise exception 'cannot report own message';
  end if;

  if exists (
    select 1 from public.chat_reports where reporter_id = v_reporter and message_id = p_message_id
  ) then
    raise exception 'already reported';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'player_name', t.player_name, 'body', t.body, 'created_at', t.created_at, 'is_target', t.id = v_msg.id
    ) order by t.created_at, t.id), '[]'::jsonb)
    into v_channel_context
  from (
    (select * from public.chat_messages
       where channel = v_msg.channel and (created_at, id) < (v_msg.created_at, v_msg.id)
       order by created_at desc, id desc limit 5)
    union all
    (select * from public.chat_messages where id = v_msg.id)
    union all
    (select * from public.chat_messages
       where channel = v_msg.channel and (created_at, id) > (v_msg.created_at, v_msg.id)
       order by created_at asc, id asc limit 5)
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object(
      'player_name', t.player_name, 'body', t.body, 'created_at', t.created_at, 'is_target', t.id = v_msg.id
    ) order by t.created_at, t.id), '[]'::jsonb)
    into v_author_context
  from (
    (select * from public.chat_messages
       where channel = v_msg.channel and player_id is not distinct from v_msg.player_id
         and (created_at, id) < (v_msg.created_at, v_msg.id)
       order by created_at desc, id desc limit 5)
    union all
    (select * from public.chat_messages where id = v_msg.id)
    union all
    (select * from public.chat_messages
       where channel = v_msg.channel and player_id is not distinct from v_msg.player_id
         and (created_at, id) > (v_msg.created_at, v_msg.id)
       order by created_at asc, id asc limit 5)
  ) t;

  insert into public.chat_reports
    (reporter_id, reported_player_id, message_id, channel, reported_body, reported_player_name,
     reason_category, reason_text, channel_context, author_context)
  values
    (v_reporter, v_msg.player_id, v_msg.id, v_msg.channel, v_msg.body, v_msg.player_name,
     p_reason_category, nullif(trim(coalesce(p_reason_text, '')), ''), v_channel_context, v_author_context)
  returning id into v_report_id;

  return v_report_id;
end;
$$;

grant execute on function public.submit_chat_report to authenticated;

-- ----------------------------------------------------------------------------
-- admin_resolve_report: 通報の処理(管理者専用)
-- ----------------------------------------------------------------------------
create or replace function public.admin_resolve_report(
  p_report_id bigint,
  p_action text,
  p_delete_message boolean default false,
  p_penalty_hours integer default null,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_report record;
  v_target uuid;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  if p_action not in ('ban_reported','penalty_reported','warn_reported','warn_reporter','penalty_reporter','ban_reporter','close') then
    raise exception 'invalid action';
  end if;

  select * into v_report from public.chat_reports where id = p_report_id for update;
  if not found then
    raise exception 'report not found';
  end if;
  if v_report.status = 'resolved' then
    raise exception 'report already resolved';
  end if;

  if p_action in ('ban_reported','penalty_reported','warn_reported') then
    v_target := v_report.reported_player_id;
  elsif p_action in ('ban_reporter','penalty_reporter','warn_reporter') then
    v_target := v_report.reporter_id;
  end if;

  if v_target is not null then
    if p_action in ('ban_reported','ban_reporter') then
      update public.players set banned_at = now(), ban_reason = coalesce(p_note, '通報対応によるBAN')
        where id = v_target;
    elsif p_action in ('penalty_reported','penalty_reporter') then
      if p_penalty_hours is null or p_penalty_hours <= 0 then
        raise exception 'penalty hours required';
      end if;
      update public.players
        set penalty_until = now() + (p_penalty_hours || ' hours')::interval,
            penalty_reason = coalesce(p_note, '通報対応による利用制限')
        where id = v_target;
    elsif p_action = 'warn_reported' then
      update public.players set warning_count = warning_count + 1 where id = v_target;
      insert into public.announcements (title, body, tags, published_at, target_player_id)
        values (
          '警告',
          coalesce(p_note, 'チャットへの投稿内容について、運営より警告いたします。利用規約に違反する投稿を繰り返した場合、アカウントの利用を制限することがあります。'),
          '[]'::jsonb, now(), v_target
        );
    elsif p_action = 'warn_reporter' then
      update public.players set warning_count = warning_count + 1 where id = v_target;
      insert into public.announcements (title, body, tags, published_at, target_player_id)
        values (
          '警告',
          coalesce(p_note, 'いただいた通報を運営で確認しましたが、妥当性が認められず、悪意のある通報(嫌がらせ)であると判断いたしました。今後このような通報を繰り返した場合、アカウントの利用を制限することがあります。'),
          '[]'::jsonb, now(), v_target
        );
    end if;
  end if;

  if p_delete_message and v_report.message_id is not null then
    delete from public.chat_messages where id = v_report.message_id;
  end if;

  update public.chat_reports
    set status = 'resolved', resolution_action = p_action, message_deleted = p_delete_message,
        resolved_by = v_admin, resolved_at = now()
    where id = p_report_id;
end;
$$;

grant execute on function public.admin_resolve_report to authenticated;

-- ----------------------------------------------------------------------------
-- save_full_state: 一時ペナルティ中の書き込みも拒否する(21引数、022と同一)
-- ----------------------------------------------------------------------------
create or replace function public.save_full_state(
  p_name text,
  p_gold integer,
  p_party jsonb,
  p_home_furniture jsonb,
  p_colosseum_floor_right integer,
  p_colosseum_medals integer,
  p_colosseum_last_challenge_at timestamptz,
  p_roster jsonb,
  p_inventory jsonb,
  p_dungeons jsonb,
  p_destiny_tickets integer default 0,
  p_guaranteed_tickets integer default 0,
  p_rift_state jsonb default null,
  p_tutorial_done boolean default true,
  p_orbs jsonb default '{}'::jsonb,
  p_materials jsonb default '{}'::jsonb,
  p_stamina integer default 100,
  p_stamina_updated_at timestamptz default now(),
  p_tools jsonb default '{}'::jsonb,
  p_tower_run jsonb default null,
  p_tower_best_floor jsonb default '{}'::jsonb
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
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

  insert into public.players (id, name, gold, party, home_furniture,
    colosseum_floor_right, colosseum_medals, colosseum_last_challenge_at,
    destiny_tickets, guaranteed_tickets, rift_state, tutorial_done, orbs, materials,
    stamina, stamina_updated_at, tools, tower_run, tower_best_floor, updated_at)
  values (v_player_id, p_name, p_gold, p_party, p_home_furniture,
    p_colosseum_floor_right, p_colosseum_medals, p_colosseum_last_challenge_at,
    p_destiny_tickets, p_guaranteed_tickets, p_rift_state, p_tutorial_done,
    coalesce(p_orbs, '{}'::jsonb), coalesce(p_materials, '{}'::jsonb),
    greatest(0, least(100, p_stamina)), p_stamina_updated_at,
    coalesce(p_tools, '{}'::jsonb), p_tower_run, coalesce(p_tower_best_floor, '{}'::jsonb), now())
  on conflict (id) do update set
    name = excluded.name, gold = excluded.gold, party = excluded.party,
    home_furniture = excluded.home_furniture,
    colosseum_floor_right = excluded.colosseum_floor_right,
    colosseum_medals = excluded.colosseum_medals,
    colosseum_last_challenge_at = excluded.colosseum_last_challenge_at,
    destiny_tickets = excluded.destiny_tickets,
    guaranteed_tickets = excluded.guaranteed_tickets,
    rift_state = excluded.rift_state,
    tutorial_done = excluded.tutorial_done,
    orbs = excluded.orbs,
    materials = excluded.materials,
    stamina = excluded.stamina,
    stamina_updated_at = excluded.stamina_updated_at,
    tools = excluded.tools,
    tower_run = excluded.tower_run,
    tower_best_floor = excluded.tower_best_floor,
    updated_at = now();

  delete from public.player_inventory
    where player_id = v_player_id
      and id not in (select value->>'id' from jsonb_array_elements(p_inventory));

  insert into public.player_inventory (id, player_id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix, enhance_level)
  select
    (item->>'id'),
    v_player_id,
    (item->>'item_type'),
    (item->>'name'),
    (item->>'rarity'),
    (item->>'value')::integer,
    (item->>'resist_element'),
    nullif(item->>'resist_value','')::integer,
    (item->>'weapon_type'),
    (item->'affix'),
    coalesce((item->>'enhance_level')::integer, 0)
  from jsonb_array_elements(p_inventory) as item
  on conflict (id) do update set
    item_type = excluded.item_type, name = excluded.name, rarity = excluded.rarity,
    value = excluded.value, resist_element = excluded.resist_element, resist_value = excluded.resist_value,
    weapon_type = excluded.weapon_type, affix = excluded.affix, enhance_level = excluded.enhance_level;

  insert into public.player_roster (player_id, liver_id, job, level, exp, hp, max_hp, mp, max_mp,
    equipped_weapon_id, equipped_armor_id, loadout, unlocked, job_progress, costume, unlocked_costumes)
  select
    v_player_id,
    (r->>'liver_id'), (r->>'job'), (r->>'level')::integer, (r->>'exp')::integer,
    (r->>'hp')::integer, (r->>'max_hp')::integer, (r->>'mp')::integer, (r->>'max_mp')::integer,
    nullif(r->>'equipped_weapon_id',''), nullif(r->>'equipped_armor_id',''),
    coalesce(r->'loadout', '[]'::jsonb), (r->>'unlocked')::boolean,
    r->'job_progress',
    (r->>'costume'), coalesce(r->'unlocked_costumes', '[]'::jsonb)
  from jsonb_array_elements(p_roster) as r
  on conflict (player_id, liver_id) do update set
    job = excluded.job, level = excluded.level, exp = excluded.exp,
    hp = excluded.hp, max_hp = excluded.max_hp, mp = excluded.mp, max_mp = excluded.max_mp,
    equipped_weapon_id = excluded.equipped_weapon_id, equipped_armor_id = excluded.equipped_armor_id,
    loadout = excluded.loadout, unlocked = excluded.unlocked, job_progress = excluded.job_progress,
    costume = excluded.costume, unlocked_costumes = excluded.unlocked_costumes;

  insert into public.player_dungeon_progress (player_id, dungeon_id, depth, progress, cleared, boss_kill_count)
  select
    v_player_id,
    (d->>'dungeon_id'), (d->>'depth')::integer, (d->>'progress')::integer,
    (d->>'cleared')::boolean, (d->>'boss_kill_count')::integer
  from jsonb_array_elements(p_dungeons) as d
  on conflict (player_id, dungeon_id) do update set
    depth = excluded.depth, progress = excluded.progress,
    cleared = excluded.cleared, boss_kill_count = excluded.boss_kill_count;
end;
$$;

grant execute on function public.save_full_state to authenticated;

-- ----------------------------------------------------------------------------
-- sync_combat_power: 一時ペナルティ中の書き込みも拒否する(017から不変の本体)
-- ----------------------------------------------------------------------------
create or replace function public.sync_combat_power()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_player_name text;
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

  select name into v_player_name from public.players where id = v_player_id;
  if v_player_name is null then
    return;
  end if;

  with job_defs(job_id, hp_mult, atk_mult, def_mult, mp_mult) as (
    values
      ('tank', 1.4::numeric, 0.75::numeric, 1.5::numeric, 0.6::numeric),
      ('dps',  0.9::numeric, 1.4::numeric,  0.8::numeric, 0.5::numeric),
      ('mage', 0.75::numeric,0.8::numeric,  0.7::numeric, 2.0::numeric)
  ),
  rows as (
    select
      pr.liver_id,
      pr.job as active_job,
      coalesce(pr.job_progress, '{}'::jsonb) as job_progress,
      case when wi.id is null then 0
        else wi.value + greatest(1, round(wi.value * 0.05))::int * coalesce(wi.enhance_level, 0)
      end as weapon_value,
      case when ai.id is null then 0
        else ai.value + greatest(1, round(ai.value * 0.05))::int * coalesce(ai.enhance_level, 0)
      end as armor_value
    from public.player_roster pr
    left join public.player_inventory wi on wi.id = pr.equipped_weapon_id
    left join public.player_inventory ai on ai.id = pr.equipped_armor_id
    where pr.player_id = v_player_id and pr.unlocked = true
  ),
  job_levels as (
    select
      r.liver_id, r.active_job, r.weapon_value, r.armor_value,
      jd.job_id, jd.hp_mult, jd.atk_mult, jd.def_mult, jd.mp_mult,
      greatest(1, coalesce((r.job_progress->jd.job_id->>'level')::int, 1)) as level
    from rows r
    cross join job_defs jd
  ),
  job_stats as (
    select
      liver_id, active_job, weapon_value, armor_value, job_id,
      round((30 + level*8) * hp_mult) as hp_stat,
      round((5 + level*2) * atk_mult) as atk_stat,
      round((2 + level) * def_mult) as def_stat,
      round((10 + level*4) * mp_mult) as mp_stat
    from job_levels
  ),
  weighted as (
    select
      liver_id,
      sum(
        case when job_id = active_job
          then (hp_stat)*1.0 + (atk_stat + weapon_value)*3.5 + (def_stat + armor_value)*3.5 + mp_stat*0.5
          else hp_stat*0.3 + atk_stat*1.0 + def_stat*1.0 + mp_stat*0.15
        end
      ) as total
    from job_stats
    group by liver_id
  )
  insert into public.liver_power_rankings (player_id, liver_id, player_name, combat_power, achieved_at, updated_at)
  select v_player_id, w.liver_id, v_player_name, round(w.total)::integer, now(), now()
  from weighted w
  on conflict (player_id, liver_id) do update set
    player_name = excluded.player_name,
    combat_power = excluded.combat_power,
    achieved_at = case
      when public.liver_power_rankings.combat_power is distinct from excluded.combat_power
        then excluded.achieved_at
        else public.liver_power_rankings.achieved_at
      end,
    updated_at = now()
  where public.liver_power_rankings.combat_power is distinct from excluded.combat_power
     or public.liver_power_rankings.player_name is distinct from excluded.player_name;
end;
$$;

grant execute on function public.sync_combat_power to authenticated;

-- ----------------------------------------------------------------------------
-- マーケット関連RPC: 一時ペナルティ中の書き込みも拒否する(028から中身のみ差し替え)
-- ----------------------------------------------------------------------------
create or replace function public.market_list_item(p_item_id text, p_price integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_item record;
  v_active_count integer;
  v_banned_at timestamptz;
  v_penalty_until timestamptz;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if p_price is null or p_price < 10 then
    raise exception 'price must be at least 10';
  end if;

  select banned_at, penalty_until into v_banned_at, v_penalty_until
    from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception 'account penalized';
  end if;

  select * into v_item from public.player_inventory
    where id = p_item_id and player_id = v_player_id;
  if not found then
    raise exception 'item not found';
  end if;

  if exists (
    select 1 from public.player_roster
      where player_id = v_player_id
        and (equipped_weapon_id = p_item_id or equipped_armor_id = p_item_id)
  ) then
    raise exception 'item is equipped';
  end if;

  select count(*) into v_active_count from public.market_listings
    where seller_id = v_player_id and status = 'active';
  if v_active_count >= 3 then
    raise exception 'listing slots full';
  end if;

  insert into public.market_listings
    (seller_id, kind, item_snapshot, quantity, price_per_unit, status, listed_at, expires_at)
  values (
    v_player_id, 'equipment',
    jsonb_build_object(
      'id', v_item.id, 'item_type', v_item.item_type, 'name', v_item.name,
      'rarity', v_item.rarity, 'value', v_item.value,
      'resist_element', v_item.resist_element, 'resist_value', v_item.resist_value,
      'weapon_type', v_item.weapon_type, 'affix', v_item.affix,
      'enhance_level', v_item.enhance_level
    ),
    1, p_price, 'active', now(), now() + interval '72 hours'
  );

  delete from public.player_inventory where id = p_item_id and player_id = v_player_id;

  insert into public.market_sale_notifications (seller_id, kind, event, item_name, quantity, price_per_unit, total_price)
  values (v_player_id, 'equipment', 'listed', v_item.name, 1, p_price, p_price);
end;
$$;

create or replace function public.market_list_stack(
  p_material_key text, p_bucket text, p_quantity integer, p_price_per_unit integer
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_current integer;
  v_active_count integer;
  v_new_qty integer;
  v_banned_at timestamptz;
  v_penalty_until timestamptz;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if p_bucket not in ('materials','tools') then
    raise exception 'invalid bucket';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'invalid quantity';
  end if;
  if p_price_per_unit is null or p_price_per_unit < 10 then
    raise exception 'price must be at least 10';
  end if;

  select banned_at, penalty_until into v_banned_at, v_penalty_until
    from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception 'account penalized';
  end if;

  select count(*) into v_active_count from public.market_listings
    where seller_id = v_player_id and status = 'active';
  if v_active_count >= 3 then
    raise exception 'listing slots full';
  end if;

  if p_bucket = 'materials' then
    select (materials->>p_material_key)::integer into v_current
      from public.players where id = v_player_id for update;
  else
    select (tools->>p_material_key)::integer into v_current
      from public.players where id = v_player_id for update;
  end if;
  v_current := coalesce(v_current, 0);
  if v_current < p_quantity then
    raise exception 'insufficient quantity';
  end if;

  v_new_qty := v_current - p_quantity;
  if p_bucket = 'materials' then
    update public.players
      set materials = jsonb_set(coalesce(materials,'{}'::jsonb), array[p_material_key], to_jsonb(v_new_qty))
      where id = v_player_id;
  else
    update public.players
      set tools = jsonb_set(coalesce(tools,'{}'::jsonb), array[p_material_key], to_jsonb(v_new_qty))
      where id = v_player_id;
  end if;

  insert into public.market_listings
    (seller_id, kind, bucket, material_key, quantity, price_per_unit, status, listed_at, expires_at)
  values (v_player_id, 'stack', p_bucket, p_material_key, p_quantity, p_price_per_unit, 'active', now(), now() + interval '72 hours');

  insert into public.market_sale_notifications (seller_id, kind, event, bucket, material_key, quantity, price_per_unit, total_price)
  values (v_player_id, 'stack', 'listed', p_bucket, p_material_key, p_quantity, p_price_per_unit, p_quantity * p_price_per_unit);

  return v_new_qty;
end;
$$;

create or replace function public.market_buy_item(p_listing_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_listing record;
  v_gold integer;
  v_new_gold integer;
  v_fee integer;
  v_received integer;
  v_banned_at timestamptz;
  v_penalty_until timestamptz;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select * into v_listing from public.market_listings
    where id = p_listing_id and kind = 'equipment' and status = 'active' and expires_at > now()
    for update;
  if not found then
    raise exception 'listing not available';
  end if;

  select gold, banned_at, penalty_until into v_gold, v_banned_at, v_penalty_until
    from public.players where id = v_player_id for update;
  if v_gold is null then
    raise exception 'player not found';
  end if;
  if v_banned_at is not null then
    raise exception 'account banned';
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception 'account penalized';
  end if;
  if v_gold < v_listing.price_per_unit then
    raise exception 'insufficient gold';
  end if;

  update public.market_listings set status = 'sold', buyer_id = v_player_id, sold_at = now()
    where id = p_listing_id;

  update public.players set gold = gold - v_listing.price_per_unit, updated_at = now()
    where id = v_player_id
    returning gold into v_new_gold;

  v_fee := v_listing.price_per_unit / 10;
  v_received := v_listing.price_per_unit - v_fee;

  if v_listing.seller_id <> v_player_id then
    insert into public.market_mailbox (player_id, gold) values (v_listing.seller_id, v_received)
      on conflict (player_id) do update set gold = public.market_mailbox.gold + excluded.gold;
  else
    update public.players set gold = gold + v_received where id = v_player_id
      returning gold into v_new_gold;
  end if;

  insert into public.market_sale_notifications (seller_id, kind, event, item_name, quantity, price_per_unit, total_price, received_amount)
  values (v_listing.seller_id, 'equipment', 'sold', v_listing.item_snapshot->>'name', 1, v_listing.price_per_unit, v_listing.price_per_unit, v_received);

  insert into public.player_inventory
    (id, player_id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix, enhance_level)
  values (
    v_listing.item_snapshot->>'id', v_player_id, v_listing.item_snapshot->>'item_type',
    v_listing.item_snapshot->>'name', v_listing.item_snapshot->>'rarity',
    (v_listing.item_snapshot->>'value')::integer,
    v_listing.item_snapshot->>'resist_element', nullif(v_listing.item_snapshot->>'resist_value','')::integer,
    v_listing.item_snapshot->>'weapon_type', v_listing.item_snapshot->'affix',
    coalesce((v_listing.item_snapshot->>'enhance_level')::integer, 0)
  );

  return jsonb_build_object('new_gold', v_new_gold, 'item', v_listing.item_snapshot);
end;
$$;

create or replace function public.market_buy_stack(
  p_material_key text, p_bucket text, p_price_per_unit integer, p_quantity integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_row record;
  v_remaining integer;
  v_take integer;
  v_total_price integer;
  v_gold integer;
  v_new_gold integer;
  v_new_qty integer;
  v_chunk_amount integer;
  v_fee integer;
  v_received integer;
  v_banned_at timestamptz;
  v_penalty_until timestamptz;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if p_bucket not in ('materials','tools') then
    raise exception 'invalid bucket';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'invalid quantity';
  end if;
  if p_price_per_unit is null or p_price_per_unit <= 0 then
    raise exception 'invalid price';
  end if;

  v_total_price := p_price_per_unit * p_quantity;

  select gold, banned_at, penalty_until into v_gold, v_banned_at, v_penalty_until
    from public.players where id = v_player_id for update;
  if v_gold is null then
    raise exception 'player not found';
  end if;
  if v_banned_at is not null then
    raise exception 'account banned';
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception 'account penalized';
  end if;
  if v_gold < v_total_price then
    raise exception 'insufficient gold';
  end if;

  v_remaining := p_quantity;
  for v_row in
    select * from public.market_listings
      where kind = 'stack' and material_key = p_material_key and bucket = p_bucket
        and price_per_unit = p_price_per_unit and status = 'active' and expires_at > now()
      order by listed_at asc, id asc
      for update
  loop
    exit when v_remaining <= 0;
    v_take := least(v_row.quantity, v_remaining);

    if v_take >= v_row.quantity then
      update public.market_listings set status = 'sold', buyer_id = v_player_id, sold_at = now()
        where id = v_row.id;
    else
      update public.market_listings set quantity = quantity - v_take where id = v_row.id;
    end if;

    v_chunk_amount := v_take * p_price_per_unit;
    v_fee := v_chunk_amount / 10;
    v_received := v_chunk_amount - v_fee;

    if v_row.seller_id <> v_player_id then
      insert into public.market_mailbox (player_id, gold) values (v_row.seller_id, v_received)
        on conflict (player_id) do update set gold = public.market_mailbox.gold + excluded.gold;
    else
      update public.players set gold = gold + v_received where id = v_player_id;
    end if;

    insert into public.market_sale_notifications (seller_id, kind, event, bucket, material_key, quantity, price_per_unit, total_price, received_amount)
    values (v_row.seller_id, 'stack', 'sold', v_row.bucket, v_row.material_key, v_take, p_price_per_unit, v_chunk_amount, v_received);

    v_remaining := v_remaining - v_take;
  end loop;

  if v_remaining > 0 then
    raise exception 'insufficient stock';
  end if;

  update public.players set gold = gold - v_total_price, updated_at = now()
    where id = v_player_id
    returning gold into v_new_gold;

  if p_bucket = 'materials' then
    v_new_qty := coalesce((select (materials->>p_material_key)::integer from public.players where id = v_player_id), 0) + p_quantity;
    update public.players
      set materials = jsonb_set(coalesce(materials,'{}'::jsonb), array[p_material_key], to_jsonb(v_new_qty))
      where id = v_player_id;
  else
    v_new_qty := coalesce((select (tools->>p_material_key)::integer from public.players where id = v_player_id), 0) + p_quantity;
    update public.players
      set tools = jsonb_set(coalesce(tools,'{}'::jsonb), array[p_material_key], to_jsonb(v_new_qty))
      where id = v_player_id;
  end if;

  return jsonb_build_object('new_gold', v_new_gold, 'new_qty', v_new_qty);
end;
$$;

create or replace function public.market_cancel_listing(p_listing_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_listing record;
  v_new_qty integer;
  v_banned_at timestamptz;
  v_penalty_until timestamptz;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select banned_at, penalty_until into v_banned_at, v_penalty_until
    from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception 'account penalized';
  end if;

  select * into v_listing from public.market_listings
    where id = p_listing_id and seller_id = v_player_id and status = 'active'
    for update;
  if not found then
    raise exception 'listing not found';
  end if;

  update public.market_listings set status = 'cancelled' where id = p_listing_id;

  if v_listing.kind = 'equipment' then
    insert into public.player_inventory
      (id, player_id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix, enhance_level)
    values (
      v_listing.item_snapshot->>'id', v_player_id, v_listing.item_snapshot->>'item_type',
      v_listing.item_snapshot->>'name', v_listing.item_snapshot->>'rarity',
      (v_listing.item_snapshot->>'value')::integer,
      v_listing.item_snapshot->>'resist_element', nullif(v_listing.item_snapshot->>'resist_value','')::integer,
      v_listing.item_snapshot->>'weapon_type', v_listing.item_snapshot->'affix',
      coalesce((v_listing.item_snapshot->>'enhance_level')::integer, 0)
    );
    return jsonb_build_object('kind', 'equipment', 'item', v_listing.item_snapshot);
  else
    if v_listing.bucket = 'materials' then
      v_new_qty := coalesce((select (materials->>v_listing.material_key)::integer from public.players where id = v_player_id), 0) + v_listing.quantity;
      update public.players
        set materials = jsonb_set(coalesce(materials,'{}'::jsonb), array[v_listing.material_key], to_jsonb(v_new_qty))
        where id = v_player_id;
    else
      v_new_qty := coalesce((select (tools->>v_listing.material_key)::integer from public.players where id = v_player_id), 0) + v_listing.quantity;
      update public.players
        set tools = jsonb_set(coalesce(tools,'{}'::jsonb), array[v_listing.material_key], to_jsonb(v_new_qty))
        where id = v_player_id;
    end if;
    return jsonb_build_object('kind', 'stack', 'bucket', v_listing.bucket, 'material_key', v_listing.material_key, 'new_qty', v_new_qty);
  end if;
end;
$$;

create or replace function public.market_claim_expired()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_row record;
  v_results jsonb := '[]'::jsonb;
  v_new_qty integer;
  v_banned_at timestamptz;
  v_penalty_until timestamptz;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select banned_at, penalty_until into v_banned_at, v_penalty_until
    from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception 'account penalized';
  end if;

  for v_row in
    select * from public.market_listings
      where seller_id = v_player_id and status = 'active' and expires_at <= now()
      for update
  loop
    update public.market_listings set status = 'expired' where id = v_row.id;

    if v_row.kind = 'equipment' then
      insert into public.player_inventory
        (id, player_id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix, enhance_level)
      values (
        v_row.item_snapshot->>'id', v_player_id, v_row.item_snapshot->>'item_type',
        v_row.item_snapshot->>'name', v_row.item_snapshot->>'rarity',
        (v_row.item_snapshot->>'value')::integer,
        v_row.item_snapshot->>'resist_element', nullif(v_row.item_snapshot->>'resist_value','')::integer,
        v_row.item_snapshot->>'weapon_type', v_row.item_snapshot->'affix',
        coalesce((v_row.item_snapshot->>'enhance_level')::integer, 0)
      );
      v_results := v_results || jsonb_build_object('kind', 'equipment', 'item', v_row.item_snapshot);

      insert into public.market_sale_notifications (seller_id, kind, event, item_name, quantity, price_per_unit, total_price)
      values (v_player_id, 'equipment', 'expired', v_row.item_snapshot->>'name', 1, v_row.price_per_unit, v_row.price_per_unit);
    else
      if v_row.bucket = 'materials' then
        v_new_qty := coalesce((select (materials->>v_row.material_key)::integer from public.players where id = v_player_id), 0) + v_row.quantity;
        update public.players
          set materials = jsonb_set(coalesce(materials,'{}'::jsonb), array[v_row.material_key], to_jsonb(v_new_qty))
          where id = v_player_id;
      else
        v_new_qty := coalesce((select (tools->>v_row.material_key)::integer from public.players where id = v_player_id), 0) + v_row.quantity;
        update public.players
          set tools = jsonb_set(coalesce(tools,'{}'::jsonb), array[v_row.material_key], to_jsonb(v_new_qty))
          where id = v_player_id;
      end if;
      v_results := v_results || jsonb_build_object('kind', 'stack', 'bucket', v_row.bucket, 'material_key', v_row.material_key, 'new_qty', v_new_qty);

      insert into public.market_sale_notifications (seller_id, kind, event, bucket, material_key, quantity, price_per_unit, total_price)
      values (v_player_id, 'stack', 'expired', v_row.bucket, v_row.material_key, v_row.quantity, v_row.price_per_unit, v_row.quantity * v_row.price_per_unit);
    end if;
  end loop;

  return v_results;
end;
$$;

create or replace function public.claim_market_mailbox()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_amount bigint;
  v_new_gold integer;
  v_banned_at timestamptz;
  v_penalty_until timestamptz;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select banned_at, penalty_until into v_banned_at, v_penalty_until
    from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception 'account penalized';
  end if;

  select gold into v_amount from public.market_mailbox where player_id = v_player_id for update;
  if v_amount is null or v_amount = 0 then
    select gold into v_new_gold from public.players where id = v_player_id;
    return coalesce(v_new_gold, 0);
  end if;

  update public.market_mailbox set gold = 0 where player_id = v_player_id;
  update public.players set gold = gold + v_amount, updated_at = now()
    where id = v_player_id
    returning gold into v_new_gold;

  return v_new_gold;
end;
$$;
