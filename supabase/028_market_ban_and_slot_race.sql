-- ============================================================================
-- 028: マーケットのBANチェック漏れと出品枠チェックの競合状態を修正
-- 001〜027 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・save_full_stateなど既存の書き込み系RPCは全て呼び出し元プレイヤーの
--     banned_atを確認しているのに、マーケットの7つのRPCにはこの
--     チェックが漏れていた。BANされたプレイヤーが出品・購入・出品取消・
--     期限切れ受け取り・売上受け取りを続けられてしまうため、他のRPCと
--     同じガードを追加する。
--   ・market_list_item/market_list_stackの「出品数が3未満か」の判定は、
--     ロック無しでカウントしてから挿入する順序だったため、同一
--     プレイヤーからほぼ同時に複数リクエストが来た場合に3枠の上限を
--     超えて出品できてしまう競合状態があった。BANチェックのために
--     players行を`for update`でロックする処理を、この枠数チェックより
--     前に置くことで、同一プレイヤーの出品リクエストを直列化し
--     ついでに解消する。
--   ・7関数とも中身だけの差し替えでシグネチャは変わらないため、drop不要。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- market_list_item
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
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if p_price is null or p_price < 10 then
    raise exception 'price must be at least 10';
  end if;

  -- players行をロックすることで、BANチェックと同時に「出品数カウント→挿入」の
  -- 一連の処理を同一プレイヤーについて直列化する(3枠チェックの競合状態対策)。
  select banned_at into v_banned_at from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
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

-- ----------------------------------------------------------------------------
-- market_list_stack
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
  v_banned_at timestamptz;
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

  -- players行をロックすることで、BANチェックと同時に3枠チェックの競合状態も解消する。
  select banned_at into v_banned_at from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
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

-- ----------------------------------------------------------------------------
-- market_buy_item
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
  v_fee integer;
  v_received integer;
  v_banned_at timestamptz;
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

  select gold, banned_at into v_gold, v_banned_at from public.players where id = v_player_id for update;
  if v_gold is null then
    raise exception 'player not found';
  end if;
  if v_banned_at is not null then
    raise exception 'account banned';
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
    -- 自分自身の出品を購入した特殊ケース: 手数料10%を差し引いた分だけ自分に戻る
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

-- ----------------------------------------------------------------------------
-- market_buy_stack
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
  v_chunk_amount integer;
  v_fee integer;
  v_received integer;
  v_banned_at timestamptz;
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

  select gold, banned_at into v_gold, v_banned_at from public.players where id = v_player_id for update;
  if v_gold is null then
    raise exception 'player not found';
  end if;
  if v_banned_at is not null then
    raise exception 'account banned';
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

-- ----------------------------------------------------------------------------
-- market_cancel_listing
-- ----------------------------------------------------------------------------
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
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select banned_at into v_banned_at from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
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

-- ----------------------------------------------------------------------------
-- market_claim_expired
-- ----------------------------------------------------------------------------
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
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select banned_at into v_banned_at from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
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

-- ----------------------------------------------------------------------------
-- claim_market_mailbox
-- ----------------------------------------------------------------------------
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
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select banned_at into v_banned_at from public.players where id = v_player_id for update;
  if v_banned_at is not null then
    raise exception 'account banned';
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
