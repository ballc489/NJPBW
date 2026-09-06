-- ============================================================================
-- 027: マーケットに10%手数料を実装(出品者には渡さず消滅)
-- 001〜026 の後に、SQL Editorで実行してください。
--
-- 経緯:
--   当初の仕様は「売上の10%を手数料として引き、出品者には90%が入る」
--   だったが、023〜026の実装時に「手数料は無し(全額出品者)」という
--   誤った解釈で実装してしまっていた。本来は「引いた10%をどこにも
--   渡さず消滅させる(ゴールドシンク)」という意図だったので、それに
--   合わせて修正する。
--
-- 仕様の要点:
--   ・買い手が支払う金額(price_per_unit、あるいはFIFOで消費した分の
--     合計)は変わらない。変わるのは出品者(market_mailbox、または
--     自己取引時は本人)に入金する額のみ。
--   ・手数料は整数除算(price / 10)で切り捨て計算する(端数は出品者
--     側に有利になる=消滅する手数料が少なくなる方向)。例: 10G→手数料
--     1G・受取9G、15G→手数料1G・受取14G、100G→手数料10G・受取90G。
--   ・market_sale_notificationsのtotal_price(取引額)はそのまま、
--     received_amount(受取額)だけが手数料控除後の値になる。
--   ・market_buy_item/market_buy_stackの中身だけを差し替える
--     (シグネチャは変わらないのでdrop不要)。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- market_buy_item: 出品者への入金額を90%(手数料10%控除後)にする
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
-- market_buy_stack: 消費した出品(行)ごとの入金額を90%(手数料10%控除後)にする
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
