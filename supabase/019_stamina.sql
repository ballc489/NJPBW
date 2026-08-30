-- ============================================================================
-- 019: スタミナシステム
-- 001〜018 の後に、SQL Editorで実行してください。
--
-- 仕様:
--   ・スタミナはライバー単位ではなくプレイヤー(アカウント)単位のリソース。
--     上限100固定、1分に1回復。ダンジョンの「奥へ進む」「ボスに挑む」で
--     1消費、次元断層ポモ・ドーロの突入で25消費する(突入自体は25分
--     かかるため、最後まで遊べば消費分はちょうど回復し切る計算。撤退
--     した場合は返ってこない)。時間経過以外の回復手段(アイテム消費・
--     広告視聴など)は今回は設けない。
--   ・players.stamina(現在値)とplayers.stamina_updated_at(最後に回復を
--     計算した時刻)の2列で持つ。実際の回復計算はクライアント側
--     (index.html)で行い、他の資源(ゴールド・チケットなど)と同じ信頼
--     モデルでそのまま保存する(サーバー側の厳密な検証はしない)。
--   ・save_full_stateの引数が2つ増える(p_stamina, p_stamina_updated_at)
--     ため、既存の16引数版を明示的に破棄してから作り直す
--     (004・006・009・017・018と同じ理由)。
-- ============================================================================

alter table public.players
  add column if not exists stamina integer not null default 100,
  add column if not exists stamina_updated_at timestamptz not null default now();

alter table public.players
  add constraint player_stamina_range check (stamina >= 0 and stamina <= 100);

drop function if exists public.save_full_state(
  text, integer, jsonb, jsonb, integer, integer, timestamptz, jsonb, jsonb, jsonb, integer, integer, jsonb, boolean, jsonb, jsonb
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
  p_stamina_updated_at timestamptz default now()
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
    stamina, stamina_updated_at, updated_at)
  values (v_player_id, p_name, p_gold, p_party, p_home_furniture,
    p_colosseum_floor_right, p_colosseum_medals, p_colosseum_last_challenge_at,
    p_destiny_tickets, p_guaranteed_tickets, p_rift_state, p_tutorial_done,
    coalesce(p_orbs, '{}'::jsonb), coalesce(p_materials, '{}'::jsonb),
    greatest(0, least(100, p_stamina)), p_stamina_updated_at, now())
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
