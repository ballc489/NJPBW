-- ============================================================================
-- 035: アクセサリー・クリスタル(新装備システムの基礎)
-- 001〜034 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・武器・防具とは別枠の第3装備スロット「アクセサリー」(1人1個)を
--     player_roster.equipped_accessory_idとして追加する。
--   ・アクセサリー本体は「主効果」1つ(effect_type/effect_value)と
--     「クリスタルスロット数」(slot_count、0〜5)を持つ。
--   ・クリスタルは「効果」1つ(同じくeffect_type/effect_value列を共用)と
--     「消費スロット数」(slot_cost、1〜3)を持ち、アクセサリーに挿すと
--     player_inventory.socketed_into にそのアクセサリーのidを持つ形で
--     紐付く(挿さっている間は所持品一覧には出さず、装備中のアクセサリー
--     に埋め込んで表示するのはクライアント側の責務)。
--   ・socketed_intoにはあえて外部キー制約を付けない(既存の
--     マーケット機能と同じく、装備可否・整合性のガードレールは
--     クライアント側の責務とする設計方針を踏襲。同一INSERT文内での
--     自己参照になるケースがあり、素直に組むのが難しいことも理由)。
--   ・効果の種類・数値の抽選ルール自体はクライアント側(index.htmlの
--     ACCESSORY_EFFECT_DEFS等)で完結しており、DB側は列を保存するだけ。
--   ・save_full_stateは引数を増やさず、既存のp_roster/p_inventory jsonb
--     配列に新しいキーが増えるだけなので、関数のシグネチャ(呼び出し方)
--     はクライアント側を変更しなくてよい。
--   ・マーケットの出品・購入・出品取消・期限切れ受取の4RPCも、
--     item_snapshotに新しい列を含めて保存・復元できるよう拡張する。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- player_inventory: アクセサリー/クリスタル用の列を追加し、item_typeの
-- CHECK制約に'accessory'・'crystal'を加える。
-- ----------------------------------------------------------------------------
alter table public.player_inventory
  add column if not exists effect_type text,
  add column if not exists effect_value numeric,
  add column if not exists slot_count integer,
  add column if not exists slot_cost integer,
  add column if not exists socketed_into text;

alter table public.player_inventory
  drop constraint if exists player_inventory_item_type_check;
alter table public.player_inventory
  add constraint player_inventory_item_type_check
  check (item_type in ('weapon','armor','accessory','crystal'));

-- ----------------------------------------------------------------------------
-- player_roster: アクセサリー装備スロット
-- ----------------------------------------------------------------------------
alter table public.player_roster
  add column if not exists equipped_accessory_id text;
alter table public.player_roster
  drop constraint if exists fk_roster_accessory;
alter table public.player_roster
  add constraint fk_roster_accessory foreign key (equipped_accessory_id)
    references public.player_inventory(id) on delete set null;

-- ----------------------------------------------------------------------------
-- save_full_state: 引数は029から不変。p_roster/p_inventoryの中身に
-- 新しいキー(equipped_accessory_id、effect_type/effect_value/slot_count/
-- slot_cost/socketed_into)が増えた分だけ、読み書きする列を追加する。
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

  insert into public.player_inventory (id, player_id, item_type, name, rarity, value,
    resist_element, resist_value, weapon_type, affix, enhance_level,
    effect_type, effect_value, slot_count, slot_cost, socketed_into)
  select
    (item->>'id'),
    v_player_id,
    (item->>'item_type'),
    (item->>'name'),
    (item->>'rarity'),
    coalesce((item->>'value')::integer, 0),
    (item->>'resist_element'),
    nullif(item->>'resist_value','')::integer,
    (item->>'weapon_type'),
    (item->'affix'),
    coalesce((item->>'enhance_level')::integer, 0),
    (item->>'effect_type'),
    nullif(item->>'effect_value','')::numeric,
    nullif(item->>'slot_count','')::integer,
    nullif(item->>'slot_cost','')::integer,
    (item->>'socketed_into')
  from jsonb_array_elements(p_inventory) as item
  on conflict (id) do update set
    item_type = excluded.item_type, name = excluded.name, rarity = excluded.rarity,
    value = excluded.value, resist_element = excluded.resist_element, resist_value = excluded.resist_value,
    weapon_type = excluded.weapon_type, affix = excluded.affix, enhance_level = excluded.enhance_level,
    effect_type = excluded.effect_type, effect_value = excluded.effect_value,
    slot_count = excluded.slot_count, slot_cost = excluded.slot_cost,
    socketed_into = excluded.socketed_into;

  insert into public.player_roster (player_id, liver_id, job, level, exp, hp, max_hp, mp, max_mp,
    equipped_weapon_id, equipped_armor_id, equipped_accessory_id, loadout, unlocked, job_progress, costume, unlocked_costumes)
  select
    v_player_id,
    (r->>'liver_id'), (r->>'job'), (r->>'level')::integer, (r->>'exp')::integer,
    (r->>'hp')::integer, (r->>'max_hp')::integer, (r->>'mp')::integer, (r->>'max_mp')::integer,
    nullif(r->>'equipped_weapon_id',''), nullif(r->>'equipped_armor_id',''), nullif(r->>'equipped_accessory_id',''),
    coalesce(r->'loadout', '[]'::jsonb), (r->>'unlocked')::boolean,
    r->'job_progress',
    (r->>'costume'), coalesce(r->'unlocked_costumes', '[]'::jsonb)
  from jsonb_array_elements(p_roster) as r
  on conflict (player_id, liver_id) do update set
    job = excluded.job, level = excluded.level, exp = excluded.exp,
    hp = excluded.hp, max_hp = excluded.max_hp, mp = excluded.mp, max_mp = excluded.max_mp,
    equipped_weapon_id = excluded.equipped_weapon_id, equipped_armor_id = excluded.equipped_armor_id,
    equipped_accessory_id = excluded.equipped_accessory_id,
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
-- マーケット4RPC: item_snapshotの保存・復元にeffect_type/effect_value/
-- slot_count/slot_costを追加する(socketed_intoは出品不可のガードで
-- 常にnull扱いになるため運ばない)。それ以外は029から不変。
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
        and (equipped_weapon_id = p_item_id or equipped_armor_id = p_item_id or equipped_accessory_id = p_item_id)
  ) then
    raise exception 'item is equipped';
  end if;
  if v_item.item_type = 'crystal' and v_item.socketed_into is not null then
    raise exception 'crystal is socketed';
  end if;
  if v_item.item_type = 'accessory' and exists (
    select 1 from public.player_inventory where socketed_into = p_item_id
  ) then
    raise exception 'accessory has crystals socketed';
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
      'enhance_level', v_item.enhance_level,
      'effect_type', v_item.effect_type, 'effect_value', v_item.effect_value,
      'slot_count', v_item.slot_count, 'slot_cost', v_item.slot_cost
    ),
    1, p_price, 'active', now(), now() + interval '72 hours'
  );

  delete from public.player_inventory where id = p_item_id and player_id = v_player_id;

  insert into public.market_sale_notifications (seller_id, kind, event, item_name, quantity, price_per_unit, total_price)
  values (v_player_id, 'equipment', 'listed', v_item.name, 1, p_price, p_price);
end;
$$;

grant execute on function public.market_list_item to authenticated;

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
    (id, player_id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix, enhance_level,
     effect_type, effect_value, slot_count, slot_cost)
  values (
    v_listing.item_snapshot->>'id', v_player_id, v_listing.item_snapshot->>'item_type',
    v_listing.item_snapshot->>'name', v_listing.item_snapshot->>'rarity',
    (v_listing.item_snapshot->>'value')::integer,
    v_listing.item_snapshot->>'resist_element', nullif(v_listing.item_snapshot->>'resist_value','')::integer,
    v_listing.item_snapshot->>'weapon_type', v_listing.item_snapshot->'affix',
    coalesce((v_listing.item_snapshot->>'enhance_level')::integer, 0),
    v_listing.item_snapshot->>'effect_type', nullif(v_listing.item_snapshot->>'effect_value','')::numeric,
    nullif(v_listing.item_snapshot->>'slot_count','')::integer, nullif(v_listing.item_snapshot->>'slot_cost','')::integer
  );

  return jsonb_build_object('new_gold', v_new_gold, 'item', v_listing.item_snapshot);
end;
$$;

grant execute on function public.market_buy_item to authenticated;

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
      (id, player_id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix, enhance_level,
       effect_type, effect_value, slot_count, slot_cost)
    values (
      v_listing.item_snapshot->>'id', v_player_id, v_listing.item_snapshot->>'item_type',
      v_listing.item_snapshot->>'name', v_listing.item_snapshot->>'rarity',
      (v_listing.item_snapshot->>'value')::integer,
      v_listing.item_snapshot->>'resist_element', nullif(v_listing.item_snapshot->>'resist_value','')::integer,
      v_listing.item_snapshot->>'weapon_type', v_listing.item_snapshot->'affix',
      coalesce((v_listing.item_snapshot->>'enhance_level')::integer, 0),
      v_listing.item_snapshot->>'effect_type', nullif(v_listing.item_snapshot->>'effect_value','')::numeric,
      nullif(v_listing.item_snapshot->>'slot_count','')::integer, nullif(v_listing.item_snapshot->>'slot_cost','')::integer
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

grant execute on function public.market_cancel_listing to authenticated;

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
        (id, player_id, item_type, name, rarity, value, resist_element, resist_value, weapon_type, affix, enhance_level,
         effect_type, effect_value, slot_count, slot_cost)
      values (
        v_row.item_snapshot->>'id', v_player_id, v_row.item_snapshot->>'item_type',
        v_row.item_snapshot->>'name', v_row.item_snapshot->>'rarity',
        (v_row.item_snapshot->>'value')::integer,
        v_row.item_snapshot->>'resist_element', nullif(v_row.item_snapshot->>'resist_value','')::integer,
        v_row.item_snapshot->>'weapon_type', v_row.item_snapshot->'affix',
        coalesce((v_row.item_snapshot->>'enhance_level')::integer, 0),
        v_row.item_snapshot->>'effect_type', nullif(v_row.item_snapshot->>'effect_value','')::numeric,
        nullif(v_row.item_snapshot->>'slot_count','')::integer, nullif(v_row.item_snapshot->>'slot_cost','')::integer
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

grant execute on function public.market_claim_expired to authenticated;
