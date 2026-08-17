-- ============================================================================
-- 007: ジョブごとの個別レベル管理(job_progress列の追加)
-- 001〜006 の後に、SQL Editorで実行してください。
--
-- 仕様:
--   ・これまで1キャラにつき単一のlevel/exp/loadoutしか持てず、ジョブを
--     切り替えると成長が共有されてしまっていた。ジョブごとに個別の
--     レベル・EXP・スキル編成を持たせるため、job_progress(jsonb)列を追加。
--     形式: {"tank":{"level":1,"exp":0,"loadout":{"enabled":[...]}}, "dps":{...}, "mage":{...}}
--   ・既存のlevel/exp/loadout列は「現在就いているジョブ」のスナップショットを
--     引き続き書き込む(互換・デバッグ用に残すだけで、読み込み時の主データは
--     job_progressを優先する)
--   ・p_roster jsonbの各要素にjob_progressが増えるだけで、save_full_stateの
--     引数の数自体は変わらないため、関数のdropは不要でcreate or replaceのみで良い
--     (005と同じ理由)
-- ============================================================================

alter table public.player_roster
  add column if not exists job_progress jsonb;

create or replace function public.save_full_state(
  p_name text,
  p_gold integer,
  p_party jsonb,
  p_home_furniture jsonb,
  p_colosseum_floor_right integer,
  p_colosseum_medals integer,
  p_colosseum_last_challenge_at timestamptz,
  p_roster jsonb,       -- [{liver_id, job, level, exp, hp, max_hp, mp, max_mp, equipped_weapon_id, equipped_armor_id, loadout, unlocked, job_progress}, ...]
  p_inventory jsonb,     -- [{id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix}, ...] (装備中のものも含む全件)
  p_dungeons jsonb,       -- [{dungeon_id, depth, progress, cleared, boss_kill_count}, ...]
  p_destiny_tickets integer default 0,
  p_guaranteed_tickets integer default 0,
  p_rift_state jsonb default null
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

  insert into public.players (id, name, gold, party, home_furniture,
    colosseum_floor_right, colosseum_medals, colosseum_last_challenge_at,
    destiny_tickets, guaranteed_tickets, rift_state, updated_at)
  values (v_player_id, p_name, p_gold, p_party, p_home_furniture,
    p_colosseum_floor_right, p_colosseum_medals, p_colosseum_last_challenge_at,
    p_destiny_tickets, p_guaranteed_tickets, p_rift_state, now())
  on conflict (id) do update set
    name = excluded.name, gold = excluded.gold, party = excluded.party,
    home_furniture = excluded.home_furniture,
    colosseum_floor_right = excluded.colosseum_floor_right,
    colosseum_medals = excluded.colosseum_medals,
    colosseum_last_challenge_at = excluded.colosseum_last_challenge_at,
    destiny_tickets = excluded.destiny_tickets,
    guaranteed_tickets = excluded.guaranteed_tickets,
    rift_state = excluded.rift_state,
    updated_at = now();

  -- 所持品: 送られてきたID一覧に無いものは削除(破棄・消費されたアイテム)してから upsert
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

  -- ロスター(先に所持品を反映してから。装備IDが所持品テーブルに存在している必要があるため)
  insert into public.player_roster (player_id, liver_id, job, level, exp, hp, max_hp, mp, max_mp,
    equipped_weapon_id, equipped_armor_id, loadout, unlocked, job_progress)
  select
    v_player_id,
    (r->>'liver_id'), (r->>'job'), (r->>'level')::integer, (r->>'exp')::integer,
    (r->>'hp')::integer, (r->>'max_hp')::integer, (r->>'mp')::integer, (r->>'max_mp')::integer,
    nullif(r->>'equipped_weapon_id',''), nullif(r->>'equipped_armor_id',''),
    coalesce(r->'loadout', '[]'::jsonb), (r->>'unlocked')::boolean,
    r->'job_progress'
  from jsonb_array_elements(p_roster) as r
  on conflict (player_id, liver_id) do update set
    job = excluded.job, level = excluded.level, exp = excluded.exp,
    hp = excluded.hp, max_hp = excluded.max_hp, mp = excluded.mp, max_mp = excluded.max_mp,
    equipped_weapon_id = excluded.equipped_weapon_id, equipped_armor_id = excluded.equipped_armor_id,
    loadout = excluded.loadout, unlocked = excluded.unlocked, job_progress = excluded.job_progress;

  -- ダンジョン進捗
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
