-- ============================================================================
-- 017: 合成(装備強化)システム
-- 001〜016 の後に、SQL Editorで実行してください。
--
-- 仕様:
--   ・player_inventory.enhance_level(0〜10)を装備ごとに保持。強化値+1で
--     効果値(value)が5%上昇(5%分が1未満なら最低+1を保証)。実効値の
--     計算はクライアント側(index.html)とsync_combat_powerの両方に
--     同じ式で実装する(itemEffectiveValue相当)。
--   ・オーブはレアリティ別にplayers.orbs(jsonb、{"common":n,...}形式)で
--     所持数を管理。入手経路は当面コロシアムメダル交換所のみ(exchange画面)。
--   ・強化自体はクライアント側で完結させ(オーブ消費・enhance_level加算)、
--     他の所持品同様save_full_stateの通常保存に乗せる。この経緯は
--     ゴールドや所持品と同じ信頼モデル(完全なチート対策はしない)を
--     踏襲したもので、新規のRPCは追加しない。
--   ・save_full_stateの引数が1つ増える(p_orbs)ため、既存の14引数版を
--     明示的に破棄してから作り直す(004・006・009と同じ理由)。
-- ============================================================================

alter table public.player_inventory
  add column if not exists enhance_level integer not null default 0;

alter table public.player_inventory
  add constraint player_inventory_enhance_level_range check (enhance_level >= 0 and enhance_level <= 10);

alter table public.players
  add column if not exists orbs jsonb not null default '{}'::jsonb;

drop function if exists public.save_full_state(
  text, integer, jsonb, jsonb, integer, integer, timestamptz, jsonb, jsonb, jsonb, integer, integer, jsonb, boolean
);

create or replace function public.save_full_state(
  p_name text,
  p_gold integer,
  p_party jsonb,
  p_home_furniture jsonb,
  p_colosseum_floor_right integer,
  p_colosseum_medals integer,
  p_colosseum_last_challenge_at timestamptz,
  p_roster jsonb,
  p_inventory jsonb,     -- [{id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix, enhance_level}, ...]
  p_dungeons jsonb,
  p_destiny_tickets integer default 0,
  p_guaranteed_tickets integer default 0,
  p_rift_state jsonb default null,
  p_tutorial_done boolean default true,
  p_orbs jsonb default '{}'::jsonb
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
    destiny_tickets, guaranteed_tickets, rift_state, tutorial_done, orbs, updated_at)
  values (v_player_id, p_name, p_gold, p_party, p_home_furniture,
    p_colosseum_floor_right, p_colosseum_medals, p_colosseum_last_challenge_at,
    p_destiny_tickets, p_guaranteed_tickets, p_rift_state, p_tutorial_done,
    coalesce(p_orbs, '{}'::jsonb), now())
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
-- sync_combat_power: 装備の実効値(強化反映後)を戦闘力計算にも使うよう更新
-- (それ以外は013から不変)
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
