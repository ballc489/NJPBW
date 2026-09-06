-- ============================================================================
-- 023: マーケット(ユーザー間アイテム売買)
-- 001〜022 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・出品は装備(1個=1商品)と、素材・道具(スタック、1個あたりの単価を
--     指定して個数分まとめて出品)の2種類。プレイヤー1人につき最大3枠。
--   ・出品は72時間で失効するが、失効しても即座には消えず、出品者が
--     マーケット画面を開いた時に受け取り(claim)処理を行うことで
--     初めて残数が所持品に戻る(cronは使わず遅延評価する設計)。
--   ・素材・道具の購入は「指定した単価の出品」を「出品が古い順」に
--     消費していく完全一致・早い者勝ちのFIFO方式。指定数量に対して
--     その単価での在庫が足りない場合は購入自体を丸ごと失敗させる
--     (部分約定はしない)。同時刻の出品はid(内部の一意な連番)の
--     若い順で処理する。
--   ・手数料は無し(売上は全額出品者に入る)。装備・素材・道具ともに、
--     どのアイテムが出品可能か(レアリティ基準・除外リストなど)は
--     クライアント側(index.htmlのMARKET_*定数)でのみ判定する。
--     これは既存の錬金・強化などと同じ信頼モデル(定義はクライアント側、
--     DB側は数値・所有権の整合性だけを保証する)を踏襲したもので、
--     出品可否そのものはゲームデザイン上のガードレールでしかないため。
--   ・出品者へのゴールド付与は、既存のcolosseum_mailboxと全く同じ
--     パターン(受け取り箱テーブル+受け取りRPC)を踏襲する。
--   ・save_full_stateはこのマーケット機能では変更しない
--     (ゴールド・素材・道具・所持品はこれまで通りクライアントの
--     state全体を毎回上書き保存する方式のままだと、マーケットの
--     非同期な入金・入庫と衝突して古い値で上書きしてしまう恐れがある
--     ため、マーケット関連のRPCは必ず処理後の「権威ある最新値」を
--     返し、クライアント側はその値をそのまま自分のstateにセットする
--     ことで整合性を保つ。差分加算はしない)。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. market_listings: 出品テーブル
-- ----------------------------------------------------------------------------
create table if not exists public.market_listings (
  id bigint generated always as identity primary key,
  seller_id uuid not null references public.players(id) on delete cascade,
  kind text not null check (kind in ('equipment','stack')),
  bucket text check (bucket in ('materials','tools')),
  material_key text,
  item_snapshot jsonb,
  quantity integer not null default 1,
  price_per_unit integer not null check (price_per_unit > 0),
  status text not null default 'active' check (status in ('active','sold','cancelled','expired')),
  buyer_id uuid references public.players(id) on delete set null,
  listed_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '72 hours'),
  sold_at timestamptz
);

create index if not exists market_listings_active_stack_idx
  on public.market_listings (material_key, bucket, price_per_unit, listed_at, id)
  where status = 'active';
create index if not exists market_listings_seller_idx
  on public.market_listings (seller_id, status);

alter table public.market_listings enable row level security;

create policy "market_listings_select" on public.market_listings
  for select using (status = 'active' or seller_id = auth.uid());
-- 出品可否のガードレール(レアリティ基準・除外リストなど)はクライアント側の
-- 責任とする方針のため、insert/update/delete用のポリシーはあえて作らない。
-- (＝直接の書き込みは常に拒否。書き込みはSECURITY DEFINER関数からのみ行う)

-- ----------------------------------------------------------------------------
-- 2. market_mailbox: 売上ゴールドの受け取り箱(colosseum_mailboxと同じ形)
-- ----------------------------------------------------------------------------
create table if not exists public.market_mailbox (
  player_id uuid primary key references public.players(id) on delete cascade,
  gold bigint not null default 0
);

alter table public.market_mailbox enable row level security;

create policy "market_mailbox_select_own" on public.market_mailbox
  for select using (auth.uid() = player_id);
-- 他人からの加算はRPC関数(SECURITY DEFINER)経由でのみ行うので、
-- 直接のinsert/updateポリシーは用意しない。

-- ----------------------------------------------------------------------------
-- 3. market_list_item: 装備を出品する
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
  if p_price is null or p_price <= 0 then
    raise exception 'invalid price';
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
-- 4. market_list_stack: 素材・道具をまとめて出品する
--    戻り値: 出品後の手元の残数(権威ある値)
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
  if p_price_per_unit is null or p_price_per_unit <= 0 then
    raise exception 'invalid price';
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
-- 5. market_buy_item: 装備を購入する
--    戻り値: { new_gold, item }
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
-- 6. market_buy_stack: 素材・道具を指定単価で指定数量購入する(古い順FIFO)
--    在庫が指定数量に満たない場合は全体を失敗させる(部分約定はしない)。
--    戻り値: { new_gold, new_qty }
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

    v_remaining := v_remaining - v_take;
  end loop;

  -- ここまでで指定数量を確保できていなければ、この関数内の全更新ごと
  -- ロールバックさせる(部分約定はしない、という仕様のため)。
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
-- 7. market_cancel_listing: 自分の出品を取り消す(残数・アイテムを手元に戻す)
--    戻り値: 装備なら {kind:'equipment', item}、スタックなら
--            {kind:'stack', bucket, material_key, new_qty}
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
begin
  if v_player_id is null then
    raise exception 'not authenticated';
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
-- 8. market_claim_expired: 期限切れになった自分の出品をまとめて受け取る
--    (cronは使わず、マーケット画面を開くたびにクライアントから呼ぶ)
--    戻り値: 上のmarket_cancel_listingと同じ形の結果をまとめたjsonb配列
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
begin
  if v_player_id is null then
    raise exception 'not authenticated';
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
    end if;
  end loop;

  return v_results;
end;
$$;

-- ----------------------------------------------------------------------------
-- 9. claim_market_mailbox: 売上ゴールドを受け取る
--    戻り値: 受け取り後の所持ゴールド(権威ある最新値。差分ではない)
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
begin
  if v_player_id is null then
    raise exception 'not authenticated';
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

-- ============================================================================
-- 権限付与
-- ============================================================================
grant select on public.market_listings to authenticated;
grant select on public.market_mailbox to authenticated;

grant execute on function public.market_list_item to authenticated;
grant execute on function public.market_list_stack to authenticated;
grant execute on function public.market_buy_item to authenticated;
grant execute on function public.market_buy_stack to authenticated;
grant execute on function public.market_cancel_listing to authenticated;
grant execute on function public.market_claim_expired to authenticated;
grant execute on function public.claim_market_mailbox to authenticated;
