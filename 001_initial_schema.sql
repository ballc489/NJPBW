-- ============================================================================
-- 灰燼記(仮) オンライン移行 初期スキーマ
-- Supabaseの SQL Editor にこのファイルの中身を丸ごと貼り付けて実行してください。
-- ============================================================================

create extension if not exists pgcrypto;


-- ----------------------------------------------------------------------------
-- 1. players: プレイヤー本体(1人1行)。id = auth.uid() をそのまま使う。
-- ----------------------------------------------------------------------------
create table if not exists public.players (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '名もなき冒険者',
  gold integer not null default 0,
  party jsonb not null default '[]'::jsonb,        -- 編成中のliver_idの配列(最大4)
  home_furniture jsonb not null default '[]'::jsonb,
  colosseum_floor_right integer not null default 1,
  colosseum_medals integer not null default 0,
  colosseum_last_challenge_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.players enable row level security;

create policy "players_select_own" on public.players
  for select using (auth.uid() = id);
create policy "players_insert_own" on public.players
  for insert with check (auth.uid() = id);
create policy "players_update_own" on public.players
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- ----------------------------------------------------------------------------
-- 2. player_roster: ライバーごとの育成状況(1人あたり最大5行、将来的にライバー
--    が増えても行が増えるだけ)
-- ----------------------------------------------------------------------------
create table if not exists public.player_roster (
  player_id uuid not null references public.players(id) on delete cascade,
  liver_id text not null,
  job text not null,
  level integer not null default 1,
  exp integer not null default 0,
  hp integer not null default 1,
  max_hp integer not null default 1,
  mp integer not null default 0,
  max_mp integer not null default 0,
  equipped_weapon_id uuid,   -- player_inventory.id を参照(下で定義)
  equipped_armor_id uuid,
  loadout jsonb not null default '[]'::jsonb,  -- 有効化中のスキルキー配列
  unlocked boolean not null default false,
  primary key (player_id, liver_id)
);

alter table public.player_roster enable row level security;

create policy "roster_select_own" on public.player_roster
  for select using (auth.uid() = player_id);
create policy "roster_insert_own" on public.player_roster
  for insert with check (auth.uid() = player_id);
create policy "roster_update_own" on public.player_roster
  for update using (auth.uid() = player_id) with check (auth.uid() = player_id);
create policy "roster_delete_own" on public.player_roster
  for delete using (auth.uid() = player_id);

-- ----------------------------------------------------------------------------
-- 3. player_inventory: 所持品(装備アイテムのインスタンス)
-- ----------------------------------------------------------------------------
create table if not exists public.player_inventory (
  id uuid primary key default gen_random_uuid(),
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

-- equipped_weapon_id / equipped_armor_id の参照制約を後付け
alter table public.player_roster
  add constraint fk_roster_weapon foreign key (equipped_weapon_id)
    references public.player_inventory(id) on delete set null;
alter table public.player_roster
  add constraint fk_roster_armor foreign key (equipped_armor_id)
    references public.player_inventory(id) on delete set null;

-- ----------------------------------------------------------------------------
-- 4. player_dungeon_progress: ダンジョンごとの踏破状況
-- ----------------------------------------------------------------------------
create table if not exists public.player_dungeon_progress (
  player_id uuid not null references public.players(id) on delete cascade,
  dungeon_id text not null,
  depth integer not null default 0,
  progress integer not null default 0,
  cleared boolean not null default false,
  boss_kill_count integer not null default 0,
  primary key (player_id, dungeon_id)
);

alter table public.player_dungeon_progress enable row level security;

create policy "dungeon_progress_select_own" on public.player_dungeon_progress
  for select using (auth.uid() = player_id);
create policy "dungeon_progress_insert_own" on public.player_dungeon_progress
  for insert with check (auth.uid() = player_id);
create policy "dungeon_progress_update_own" on public.player_dungeon_progress
  for update using (auth.uid() = player_id) with check (auth.uid() = player_id);

-- ----------------------------------------------------------------------------
-- 5. colosseum_floors: 全プレイヤー共有の門番データ(フロアごとに1行)
--    読み取りは誰でも可能(挑戦前に相手の情報を見る必要があるため)。
--    書き込みは直接行わせず、下のRPC関数経由でのみ行う。
-- ----------------------------------------------------------------------------
create table if not exists public.colosseum_floors (
  floor integer primary key,
  holder_id uuid references public.players(id) on delete set null,
  holder_name text,
  snapshot jsonb not null default '[]'::jsonb,
  hp_pool integer not null default 0,
  max_hp_pool integer not null default 0,
  wins integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.colosseum_floors enable row level security;

create policy "colosseum_floors_select_all" on public.colosseum_floors
  for select using (true);
-- insert/update/delete用のポリシーはあえて作らない
-- (＝直接の書き込みは常に拒否。書き込みはSECURITY DEFINER関数からのみ行う)

-- ----------------------------------------------------------------------------
-- 6. colosseum_mailbox: 防衛勝利メダルの受け取り箱
-- ----------------------------------------------------------------------------
create table if not exists public.colosseum_mailbox (
  player_id uuid primary key references public.players(id) on delete cascade,
  medals integer not null default 0
);

alter table public.colosseum_mailbox enable row level security;

create policy "mailbox_select_own" on public.colosseum_mailbox
  for select using (auth.uid() = player_id);
-- 他人からの加算はRPC関数(SECURITY DEFINER)経由でのみ行うので、
-- 直接のinsert/updateポリシーは用意しない。

-- ----------------------------------------------------------------------------
-- 7. chat_messages: グローバルチャット
-- ----------------------------------------------------------------------------
create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  player_id uuid references public.players(id) on delete set null,
  player_name text not null,
  body text not null check (char_length(body) between 1 and 200),
  created_at timestamptz not null default now()
);

alter table public.chat_messages enable row level security;

create policy "chat_select_all" on public.chat_messages
  for select using (true);
create policy "chat_insert_own" on public.chat_messages
  for insert with check (auth.uid() = player_id);

-- 直近100件だけ見せれば十分なので、取得時は
-- "order by created_at desc limit 100" をクライアント側のクエリで指定する想定。

-- ============================================================================
-- RPC関数: コロシアムタワーの勝敗処理(SECURITY DEFINER)
-- クライアントは「与えたダメージ」と「勝ったかどうか」を送るだけで、
-- メダル計算・門番の入れ替え・メールボックスへの加算はすべてこの関数内で
-- サーバー側が一括で行う。これにより:
--   - メダル枚数をクライアントが偽装できない
--   - 同時アクセスによる上書き事故が起きない(1トランザクション内で完結)
-- ============================================================================
create or replace function public.resolve_colosseum_battle(
  p_floor integer,
  p_damage_dealt integer,
  p_won boolean,
  p_new_snapshot jsonb default null,   -- 勝利時: 挑戦者の現在パーティのスナップショット
  p_new_max_hp_pool integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_row public.colosseum_floors%rowtype;
  v_medals integer := 0;
  v_result jsonb;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if p_floor < 1 or p_floor > 10 then
    raise exception 'invalid floor';
  end if;
  if p_damage_dealt < 0 then
    raise exception 'invalid damage';
  end if;

  -- 行ロックを取りつつ現在の門番レコードを取得(無ければ新規扱い=ダミー相手だった)
  select * into v_row from public.colosseum_floors where floor = p_floor for update;

  if p_won then
    v_medals := case when p_floor >= 10 then 50 else 1 end;

    insert into public.colosseum_floors (floor, holder_id, holder_name, snapshot, hp_pool, max_hp_pool, wins, updated_at)
    values (
      p_floor, v_player_id,
      (select name from public.players where id = v_player_id),
      coalesce(p_new_snapshot, '[]'::jsonb),
      coalesce(p_new_max_hp_pool, 0),
      coalesce(p_new_max_hp_pool, 0),
      0, now()
    )
    on conflict (floor) do update set
      holder_id = excluded.holder_id,
      holder_name = excluded.holder_name,
      snapshot = excluded.snapshot,
      hp_pool = excluded.hp_pool,
      max_hp_pool = excluded.max_hp_pool,
      wins = 0,
      updated_at = now();

    update public.players
      set colosseum_medals = colosseum_medals + v_medals,
          colosseum_floor_right = case when p_floor < 10 then p_floor + 1 else 10 end,
          colosseum_last_challenge_at = now(),
          updated_at = now()
      where id = v_player_id;

  else
    if v_row.holder_id is not null then
      -- 実在の門番だった場合のみ、ダメージと防衛勝利数を永続化する
      update public.colosseum_floors
        set hp_pool = greatest(0, hp_pool - p_damage_dealt),
            wins = wins + 1,
            updated_at = now()
        where floor = p_floor;

      v_medals := p_floor;
      if v_row.holder_id <> v_player_id then
        insert into public.colosseum_mailbox (player_id, medals)
        values (v_row.holder_id, v_medals)
        on conflict (player_id) do update set medals = public.colosseum_mailbox.medals + v_medals;
      else
        -- 自分自身の記録に挑んで負けた特殊ケース: 自分に直接加算
        update public.players set colosseum_medals = colosseum_medals + v_medals where id = v_player_id;
      end if;
    end if;
    -- holder_idがNULL(=まだ誰も登録していないダミー相手)への敗北は何も永続化しない

    update public.players
      set colosseum_floor_right = case when p_floor > 1 then 1 else colosseum_floor_right end,
          colosseum_last_challenge_at = now(),
          updated_at = now()
      where id = v_player_id;
  end if;

  select jsonb_build_object('medals_gained', v_medals, 'won', p_won) into v_result;
  return v_result;
end;
$$;

-- ============================================================================
-- RPC関数: 自分宛てのメールボックスを受け取る
-- ============================================================================
create or replace function public.claim_colosseum_mailbox()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_medals integer := 0;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select medals into v_medals from public.colosseum_mailbox where player_id = v_player_id for update;
  if v_medals is null or v_medals = 0 then
    return 0;
  end if;

  update public.colosseum_mailbox set medals = 0 where player_id = v_player_id;
  update public.players set colosseum_medals = colosseum_medals + v_medals, updated_at = now() where id = v_player_id;

  return v_medals;
end;
$$;

-- ============================================================================
-- 初期データ: コロシアム1〜10Fの行を用意しておく(holder_idはNULL=まだ誰もいない)
-- ============================================================================
insert into public.colosseum_floors (floor, holder_id, holder_name, snapshot, hp_pool, max_hp_pool, wins)
select f, null, null, '[]'::jsonb, 0, 0, 0
from generate_series(1, 10) as f
on conflict (floor) do nothing;

-- ============================================================================
-- 権限付与(Data API / PostgREST経由でアクセスするために必須)
-- RLSポリシーは「どの行にアクセスできるか」を絞る仕組みで、
-- そもそも「そのテーブルに触ってよいか」はこのGRANTで別途許可する必要がある。
-- 匿名認証でログインしたユーザーも、Supabase上では authenticated ロールになる。
-- ============================================================================
grant usage on schema public to authenticated;

grant select, insert, update on public.players to authenticated;
grant select, insert, update, delete on public.player_roster to authenticated;
grant select, insert, update, delete on public.player_inventory to authenticated;
grant select, insert, update on public.player_dungeon_progress to authenticated;
grant select on public.colosseum_floors to authenticated;
grant select on public.colosseum_mailbox to authenticated;
grant select, insert on public.chat_messages to authenticated;

grant execute on function public.resolve_colosseum_battle to authenticated;
grant execute on function public.claim_colosseum_mailbox to authenticated;
