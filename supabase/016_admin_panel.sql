-- ============================================================================
-- 016: 管理画面(admin.html)の基盤
-- 001〜015 の後に、SQL Editorで実行してください。
--
-- 管理者は、プレイヤーが使っている匿名認証とは別に、メール+パスワードの
-- 通常のSupabase認証でログインする(admin.html側で signInWithPassword を
-- 使う)。「誰が管理者か」はDB側のadminsテーブルに置き、書き込み系は
-- 必ずRPC側でis_admin()を確認してから実行する(クライアント側でUIを
-- 隠すだけでは誰でもRPCを直接叩けてしまうため、判定は必ずサーバー側に
-- 置く)。
--
-- adminsテーブルへの登録自体はSQL Editorから手動で行う想定(管理者を
-- 管理者が追加する、という再帰的な仕組みは今回作らない)。
-- ============================================================================

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;

drop policy if exists "admins_select_self" on public.admins;
create policy "admins_select_self" on public.admins
  for select using (auth.uid() = user_id);

grant select on public.admins to authenticated;

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists(select 1 from public.admins where user_id = auth.uid());
$$;

grant execute on function public.is_admin to authenticated;

-- players: 管理者は全行を閲覧できるようにする(既存のplayers_select_own
-- ポリシーと併用され、OR条件として扱われる)。
drop policy if exists "players_select_admin" on public.players;
create policy "players_select_admin" on public.players
  for select using (public.is_admin());

-- announcements: 管理者は掲載日時が未来のもの(予約投稿)も含めて
-- 全件閲覧できるようにする。
drop policy if exists "announcements_select_admin" on public.announcements;
create policy "announcements_select_admin" on public.announcements
  for select using (public.is_admin());

-- ----------------------------------------------------------------------------
-- BAN/解除
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_ban(p_target_id uuid, p_banned boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  update public.players
    set banned_at = case when p_banned then now() else null end,
        ban_reason = case when p_banned then p_reason else null end
    where id = p_target_id;
end;
$$;

grant execute on function public.admin_set_ban to authenticated;

-- ----------------------------------------------------------------------------
-- お知らせの作成・編集・削除
-- ----------------------------------------------------------------------------
create or replace function public.admin_upsert_announcement(
  p_title text,
  p_body text,
  p_id bigint default null,
  p_tags jsonb default '[]'::jsonb,
  p_published_at timestamptz default now()
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  if p_id is null then
    insert into public.announcements (title, body, tags, published_at)
    values (p_title, p_body, p_tags, p_published_at)
    returning id into v_id;
  else
    update public.announcements
      set title = p_title, body = p_body, tags = p_tags, published_at = p_published_at
      where id = p_id
      returning id into v_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_upsert_announcement to authenticated;

create or replace function public.admin_delete_announcement(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  delete from public.announcements where id = p_id;
end;
$$;

grant execute on function public.admin_delete_announcement to authenticated;
