-- ============================================================================
-- 025: マーケット通知に「出品した」「期限切れで返却された」を追加
-- 001〜024 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・market_sale_notifications(024で追加)は「売れた」通知専用だったが、
--     出品した時・出品が72時間の期限切れで手元に返却された時も同じ
--     マーケット通知欄に残るようにしたいので、event列(sold/listed/expired)
--     を追加して汎用化する。既存行は全て売却なので、デフォルト値'sold'で
--     問題なく後方互換になる。
--   ・market_buy_item/market_buy_stackは変更不要(eventのデフォルトが
--     'sold'なので、既存のinsert文のままで正しい値が入る)。
--   ・market_list_item/market_list_stack/market_claim_expiredの中身だけを
--     差し替える(シグネチャは変わらないのでdrop不要)。
-- ============================================================================

alter table public.market_sale_notifications
  add column if not exists event text not null default 'sold';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'market_sale_notifications_event_check'
  ) then
    alter table public.market_sale_notifications
      add constraint market_sale_notifications_event_check check (event in ('sold','listed','expired'));
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- market_list_item: 出品成功時に「出品した」通知を記録する
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

  insert into public.market_sale_notifications (seller_id, kind, event, item_name, quantity, price_per_unit, total_price)
  values (v_player_id, 'equipment', 'listed', v_item.name, 1, p_price, p_price);
end;
$$;

-- ----------------------------------------------------------------------------
-- market_list_stack: 出品成功時に「出品した」通知を記録する
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

  insert into public.market_sale_notifications (seller_id, kind, event, bucket, material_key, quantity, price_per_unit, total_price)
  values (v_player_id, 'stack', 'listed', p_bucket, p_material_key, p_quantity, p_price_per_unit, p_quantity * p_price_per_unit);

  return v_new_qty;
end;
$$;

-- ----------------------------------------------------------------------------
-- market_claim_expired: 返却の都度「期限切れで返却された」通知を記録する
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
