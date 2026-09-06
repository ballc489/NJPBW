-- ============================================================================
-- 024: マーケットの改善(最低出品価格・売却通知)
-- 001〜023 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・出品の最低単価を10Gとする(以前想定していた手数料10%が整数として
--     成り立つ最低値だった名残りだが、手数料が無くなった後もキリの良い
--     下限として維持する)。市場既存の関数の中身だけを差し替えるので、
--     シグネチャ(引数)は変わらず、drop不要でcreate or replaceのみで良い。
--   ・出品した商品が売れたことを、ログに紛れず気付けるようにするための
--     通知の仕組み。market_sale_notifications(誰の・何が・いくらで売れたか
--     の記録)と、players.market_last_seen_at(最後にこの通知一覧を開いた
--     時刻。バッジの未読件数計算に使う)を追加する。
--     素材・道具の名前はクライアント側の定義にしかないため、スタックの
--     通知は素材キー(bucket/material_key)だけを持ち、表示名は
--     クライアント側で解決する(装備は個体ごとに名前が違うため、
--     item_snapshotと同様にitem_nameを直接書き込む)。
-- ============================================================================

alter table public.players
  add column if not exists market_last_seen_at timestamptz not null default now();

create table if not exists public.market_sale_notifications (
  id bigint generated always as identity primary key,
  seller_id uuid not null references public.players(id) on delete cascade,
  kind text not null check (kind in ('equipment','stack')),
  item_name text,
  bucket text,
  material_key text,
  quantity integer not null default 1,
  price_per_unit integer not null,
  total_price integer not null,
  created_at timestamptz not null default now()
);

create index if not exists market_sale_notifications_seller_idx
  on public.market_sale_notifications (seller_id, created_at desc);

alter table public.market_sale_notifications enable row level security;

create policy "market_sale_notifications_select_own" on public.market_sale_notifications
  for select using (seller_id = auth.uid());
-- 書き込みはmarket_buy_item/market_buy_stack(SECURITY DEFINER)からのみ行うので、
-- insert/update/delete用のポリシーは用意しない。

-- ----------------------------------------------------------------------------
-- market_list_item: 最低価格チェックを追加
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
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if p_price is null or p_price < 10 then
    raise exception 'price must be at least 10';
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
end;
$$;

-- ----------------------------------------------------------------------------
-- market_list_stack: 最低単価チェックを追加
-- ----------------------------------------------------------------------------
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

  return v_new_qty;
end;
$$;

-- ----------------------------------------------------------------------------
-- market_buy_item: 購入時に出品者宛ての売却通知を1件記録する
-- ----------------------------------------------------------------------------
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

  select gold into v_gold from public.players where id = v_player_id for update;
  if v_gold is null then
    raise exception 'player not found';
  end if;
  if v_gold < v_listing.price_per_unit then
    raise exception 'insufficient gold';
  end if;

  update public.market_listings set status = 'sold', buyer_id = v_player_id, sold_at = now()
    where id = p_listing_id;

  update public.players set gold = gold - v_listing.price_per_unit, updated_at = now()
    where id = v_player_id
    returning gold into v_new_gold;

  if v_listing.seller_id <> v_player_id then
    insert into public.market_mailbox (player_id, gold) values (v_listing.seller_id, v_listing.price_per_unit)
      on conflict (player_id) do update set gold = public.market_mailbox.gold + excluded.gold;
  else
    -- 自分自身の出品を購入した特殊ケース: 支払った分をそのまま自分に戻す
    update public.players set gold = gold + v_listing.price_per_unit where id = v_player_id
      returning gold into v_new_gold;
  end if;

  insert into public.market_sale_notifications (seller_id, kind, item_name, quantity, price_per_unit, total_price)
  values (v_listing.seller_id, 'equipment', v_listing.item_snapshot->>'name', 1, v_listing.price_per_unit, v_listing.price_per_unit);

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

-- ----------------------------------------------------------------------------
-- market_buy_stack: 消費した出品(行)ごとに、出品者宛ての売却通知を記録する
-- ----------------------------------------------------------------------------
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

  select gold into v_gold from public.players where id = v_player_id for update;
  if v_gold is null then
    raise exception 'player not found';
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

    if v_row.seller_id <> v_player_id then
      insert into public.market_mailbox (player_id, gold) values (v_row.seller_id, v_take * p_price_per_unit)
        on conflict (player_id) do update set gold = public.market_mailbox.gold + excluded.gold;
    else
      update public.players set gold = gold + (v_take * p_price_per_unit) where id = v_player_id;
    end if;

    insert into public.market_sale_notifications (seller_id, kind, bucket, material_key, quantity, price_per_unit, total_price)
    values (v_row.seller_id, 'stack', v_row.bucket, v_row.material_key, v_take, p_price_per_unit, v_take * p_price_per_unit);

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

-- ----------------------------------------------------------------------------
-- mark_market_notifications_seen: 通知一覧を開いた時に既読時刻を更新する
-- ----------------------------------------------------------------------------
create or replace function public.mark_market_notifications_seen()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  update public.players set market_last_seen_at = now() where id = v_player_id;
end;
$$;

grant select on public.market_sale_notifications to authenticated;
grant execute on function public.mark_market_notifications_seen to authenticated;
