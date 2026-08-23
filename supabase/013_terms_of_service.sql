-- ============================================================================
-- 013: 利用規約への同意フロー・BAN機能
-- 001〜012 の後に、SQL Editorで実行してください。
--
-- 背景:
--   不正行為をしたアカウントを利用停止(BAN)できるようにするための
--   正当な根拠として、また二次創作であること・広告収益は運営コスト
--   相当に充てる旨を理解してもらうために、利用規約への同意フローを
--   追加する。法的に完璧な文書であることは求めず、一般論として妥当な
--   内容が揃っていれば良いという方針(index.html側にドラフトを記載)。
--
--   管理画面(admin UI)は現状用意しない。BANはこれまでの運用と同じく、
--   Supabase側のSQL Editorから手動でplayers.banned_atを立てる想定。
--
--   同意はバージョン管理する(players.tos_agreed_version)。クライアント側の
--   CURRENT_TOS_VERSIONより低い場合は、ログイン時に再同意を求める
--   (規約を変更した際は、index.html側でCURRENT_TOS_VERSIONを上げるだけで
--   既存プレイヤー全員に再同意ダイアログが出るようになる)。
--
--   BAN済みアカウントの書き込みを確実に止めるため、save_full_state
--   (invoker)・sync_combat_power(definer)・resolve_colosseum_battle
--   (definer)の3つの書き込み系RPCすべての冒頭でbanned_atをチェックする。
--   いずれも引数の数・型は変わらないため、関数のdropは不要でcreate or
--   replaceのみで良い。
-- ============================================================================

alter table public.players
  add column if not exists tos_agreed_version integer,
  add column if not exists banned_at timestamptz,
  add column if not exists ban_reason text;

-- ----------------------------------------------------------------------------
-- 利用規約への同意を記録する。
--
-- キャラ作成前(=players行がまだ存在しない)状態でも呼べる必要があるが、
-- insert ... on conflict do updateにすると「players行が無ければ新規プレイヤー」
-- というloadGame()側の新規プレイヤー判定(playerRowがnull)を壊してしまう
-- (行が無いだけの空アカウントが誤って「既存プレイヤー」として扱われ、
-- キャラ作成画面がスキップされてしまう)。そのため、行が存在する場合のみ
-- 更新するupdateのみとし、行がまだ無い間の同意記録はクライアント側の
-- localStorageで一時的に保持し、キャラ作成完了(=players行が実際に
-- 作られたタイミング)で改めてこの関数を呼び直して同期する設計にする
-- (index.html側のhandleAgreeTos/キャラ作成ボタンのハンドラを参照)。
-- ----------------------------------------------------------------------------
create or replace function public.agree_to_tos(p_version integer)
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

  update public.players
    set tos_agreed_version = p_version, updated_at = now()
    where id = v_player_id;
end;
$$;

grant execute on function public.agree_to_tos to authenticated;

-- ----------------------------------------------------------------------------
-- save_full_state: 冒頭にBANチェックを追加(それ以外は009・010から不変)
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
  p_tutorial_done boolean default true
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

  insert into public.players (id, name, gold, party, home_furniture,
    colosseum_floor_right, colosseum_medals, colosseum_last_challenge_at,
    destiny_tickets, guaranteed_tickets, rift_state, tutorial_done, updated_at)
  values (v_player_id, p_name, p_gold, p_party, p_home_furniture,
    p_colosseum_floor_right, p_colosseum_medals, p_colosseum_last_challenge_at,
    p_destiny_tickets, p_guaranteed_tickets, p_rift_state, p_tutorial_done, now())
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
    updated_at = now();

  delete from public.player_inventory
    where player_id = v_player_id
      and id not in (select value->>'id' from jsonb_array_elements(p_inventory));

  insert into public.player_inventory (id, player_id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix)
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
    (item->'affix')
  from jsonb_array_elements(p_inventory) as item
  on conflict (id) do update set
    item_type = excluded.item_type, name = excluded.name, rarity = excluded.rarity,
    value = excluded.value, resist_element = excluded.resist_element, resist_value = excluded.resist_value,
    weapon_type = excluded.weapon_type, affix = excluded.affix;

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
-- sync_combat_power: 冒頭にBANチェックを追加(それ以外は011から不変)
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
      coalesce(wi.value, 0) as weapon_value,
      coalesce(ai.value, 0) as armor_value
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
-- resolve_colosseum_battle: 冒頭にBANチェックを追加(それ以外は008から不変)
-- ----------------------------------------------------------------------------
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
