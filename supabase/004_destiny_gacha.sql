-- ============================================================================
-- 004: ライバー解放をダンジョン直結から「運命のチケット」ガチャ方式へ変更
-- 001, 002, 003 の後に、SQL Editorで実行してください。
--
-- 仕様:
--   ・ダンジョン初回踏破で「運命のチケット」を1枚入手
--   ・「運命のチケット」を消費すると、未解放ライバーの中からランダムに
--     1名を仲間にできる(交換所のガチャ)
--   ・「運命のチケット」5枚を「確約されし運命のチケット」1枚と交換でき、
--     こちらは未解放ライバーを指名して確実に仲間にできる
--   ・引き直し(広告視聴)回数のような一時的なUI状態はクライアント側のみで
--     保持し、DBには保存しない
-- ============================================================================

alter table public.players
  add column if not exists destiny_tickets integer not null default 0,
  add column if not exists guaranteed_tickets integer not null default 0;

-- 既存のsave_full_state(10引数版)を明示的に破棄してから、
-- チケット2つを引数に加えた新しい定義で作り直す。
-- (引数の数が変わるcreate or replaceは、古い定義を残したまま新しい
--  オーバーロードを追加してしまうため、必ずdropしてから作り直すこと)
drop function if exists public.save_full_state(
  text, integer, jsonb, jsonb, integer, integer, timestamptz, jsonb, jsonb, jsonb
);

create or replace function public.save_full_state(
  p_name text,
  p_gold integer,
  p_party jsonb,
  p_home_furniture jsonb,
  p_colosseum_floor_right integer,
  p_colosseum_medals integer,
  p_colosseum_last_challenge_at timestamptz,
  p_roster jsonb,       -- [{liver_id, job, level, exp, hp, max_hp, mp, max_mp, equipped_weapon_id, equipped_armor_id, loadout, unlocked}, ...]
  p_inventory jsonb,     -- [{id, item_type, name, rarity, value, resist_element, resist_value}, ...] (装備中のものも含む全件)
  p_dungeons jsonb,       -- [{dungeon_id, depth, progress, cleared, boss_kill_count}, ...]
  p_destiny_tickets integer default 0,
  p_guaranteed_tickets integer default 0
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
    destiny_tickets, guaranteed_tickets, updated_at)
  values (v_player_id, p_name, p_gold, p_party, p_home_furniture,
    p_colosseum_floor_right, p_colosseum_medals, p_colosseum_last_challenge_at,
    p_destiny_tickets, p_guaranteed_tickets, now())
  on conflict (id) do update set
    name = excluded.name, gold = excluded.gold, party = excluded.party,
    home_furniture = excluded.home_furniture,
    colosseum_floor_right = excluded.colosseum_floor_right,
    colosseum_medals = excluded.colosseum_medals,
    colosseum_last_challenge_at = excluded.colosseum_last_challenge_at,
    destiny_tickets = excluded.destiny_tickets,
    guaranteed_tickets = excluded.guaranteed_tickets,
    updated_at = now();

  -- 所持品: 送られてきたID一覧に無いものは削除(破棄・消費されたアイテム)してから upsert
  delete from public.player_inventory
    where player_id = v_player_id
      and id not in (select value->>'id' from jsonb_array_elements(p_inventory));

  insert into public.player_inventory (id, player_id, item_type, name, rarity, value, resist_element, resist_value)
  select
    (item->>'id'),
    v_player_id,
    (item->>'item_type'),
    (item->>'name'),
    (item->>'rarity'),
    (item->>'value')::integer,
    (item->>'resist_element'),
    nullif(item->>'resist_value','')::integer
  from jsonb_array_elements(p_inventory) as item
  on conflict (id) do update set
    item_type = excluded.item_type, name = excluded.name, rarity = excluded.rarity,
    value = excluded.value, resist_element = excluded.resist_element, resist_value = excluded.resist_value;

  -- ロスター(先に所持品を反映してから。装備IDが所持品テーブルに存在している必要があるため)
  insert into public.player_roster (player_id, liver_id, job, level, exp, hp, max_hp, mp, max_mp,
    equipped_weapon_id, equipped_armor_id, loadout, unlocked)
  select
    v_player_id,
    (r->>'liver_id'), (r->>'job'), (r->>'level')::integer, (r->>'exp')::integer,
    (r->>'hp')::integer, (r->>'max_hp')::integer, (r->>'mp')::integer, (r->>'max_mp')::integer,
    nullif(r->>'equipped_weapon_id',''), nullif(r->>'equipped_armor_id',''),
    coalesce(r->'loadout', '[]'::jsonb), (r->>'unlocked')::boolean
  from jsonb_array_elements(p_roster) as r
  on conflict (player_id, liver_id) do update set
    job = excluded.job, level = excluded.level, exp = excluded.exp,
    hp = excluded.hp, max_hp = excluded.max_hp, mp = excluded.mp, max_mp = excluded.max_mp,
    equipped_weapon_id = excluded.equipped_weapon_id, equipped_armor_id = excluded.equipped_armor_id,
    loadout = excluded.loadout, unlocked = excluded.unlocked;

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
