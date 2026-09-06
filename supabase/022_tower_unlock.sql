-- ============================================================================
-- 022: 七彩の塔の解放条件(塔ごとの過去最高到達フロア)
-- 001〜021 の後に、SQL Editorで実行してください。
--
-- 仕様:
--   ・七彩の塔全体の解放条件(チュートリアルを除く5番目のダンジョン=
--     蒼氷の霊峰の最上階クリア)は、既存のplayer_dungeon_progressだけで
--     判定できるため、新しい永続化は不要。
--   ・個別の塔どうしの解放条件(例: 紺碧の塔は紅蓮の塔50F踏破が必要)の
--     ために、塔ごとの過去最高到達フロアをplayers.tower_best_floor
--     (jsonb、{towerId: floor, ...}形式)で持つ。塔の定義(どの塔が
--     どの塔の何階踏破を要求するか)はすべてクライアント側
--     (index.html のTOWER_DEFS)にあり、DB側は数値の永続化のみ。
--   ・save_full_stateの引数が1つ増える(p_tower_best_floor)ため、既存の
--     20引数版を明示的に破棄してから作り直す(004・006・009・017・018・
--     019・020・021と同じ理由)。
-- ============================================================================

alter table public.players
  add column if not exists tower_best_floor jsonb not null default '{}'::jsonb;

drop function if exists public.save_full_state(
  text, integer, jsonb, jsonb, integer, integer, timestamptz, jsonb, jsonb, jsonb, integer, integer, jsonb, boolean, jsonb, jsonb, integer, timestamptz, jsonb, jsonb
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
