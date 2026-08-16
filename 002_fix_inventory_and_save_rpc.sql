-- ============================================================================
-- 002: player_inventory.id の型修正 + 一括保存RPC関数の追加
-- 001の後に、追加でこのファイルの中身をSQL Editorで実行してください。
-- (まだ実データが無い前提のため、player_inventory / player_roster の
--  関連カラムを一度作り直します)
-- ============================================================================

-- 既存の外部キー制約と、型が合っていなかったカラムをいったん外す
alter table public.player_roster drop constraint if exists fk_roster_weapon;
alter table public.player_roster drop constraint if exists fk_roster_armor;
alter table public.player_roster drop column if exists equipped_weapon_id;
alter table public.player_roster drop column if exists equipped_armor_id;

-- player_inventory.id を、クライアント側生成の文字列ID(例: itm_xxxxxxx)に
-- 対応できる text 型に作り直す
drop table if exists public.player_inventory;

create table public.player_inventory (
  id text primary key,                 -- クライアント側で生成したID(itm_xxxxxxx形式)をそのまま使う
  player_id uuid not null references public.players(id) on delete cascade,
  item_type text not null check (item_type in ('weapon','armor')),
  name text not null,
  rarity text not null default 'common',
  value integer not null default 0,
  resist_element text,
  resist_value integer,
  created_at timestamptz not null default now()
);

alter table public.player_inventory enable row level security;

create policy "inventory_select_own" on public.player_inventory
  for select using (auth.uid() = player_id);
create policy "inventory_insert_own" on public.player_inventory
  for insert with check (auth.uid() = player_id);
create policy "inventory_update_own" on public.player_inventory
  for update using (auth.uid() = player_id) with check (auth.uid() = player_id);
create policy "inventory_delete_own" on public.player_inventory
  for delete using (auth.uid() = player_id);

grant select, insert, update, delete on public.player_inventory to authenticated;

-- player_roster側の装備参照カラムをtext型で作り直す
alter table public.player_roster add column equipped_weapon_id text;
alter table public.player_roster add column equipped_armor_id text;
alter table public.player_roster
  add constraint fk_roster_weapon foreign key (equipped_weapon_id)
    references public.player_inventory(id) on delete set null;
alter table public.player_roster
  add constraint fk_roster_armor foreign key (equipped_armor_id)
    references public.player_inventory(id) on delete set null;

-- ============================================================================
-- RPC関数: ゲーム状態の一括保存
-- クライアントは1回のRPC呼び出しで、players / player_roster /
-- player_inventory / player_dungeon_progress をまとめて更新できる。
-- (通信回数を1回に抑えるための設計)
-- ============================================================================
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
  p_dungeons jsonb        -- [{dungeon_id, depth, progress, cleared, boss_kill_count}, ...]
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
    colosseum_floor_right, colosseum_medals, colosseum_last_challenge_at, updated_at)
  values (v_player_id, p_name, p_gold, p_party, p_home_furniture,
    p_colosseum_floor_right, p_colosseum_medals, p_colosseum_last_challenge_at, now())
  on conflict (id) do update set
    name = excluded.name, gold = excluded.gold, party = excluded.party,
    home_furniture = excluded.home_furniture,
    colosseum_floor_right = excluded.colosseum_floor_right,
    colosseum_medals = excluded.colosseum_medals,
    colosseum_last_challenge_at = excluded.colosseum_last_challenge_at,
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
