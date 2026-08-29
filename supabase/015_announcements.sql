-- ============================================================================
-- 015: お知らせ機能(announcements + 既読管理)
-- 001〜014 の後に、SQL Editorで実行してください。
--
-- 管理画面(admin UI)は用意しない。お知らせの追加・編集は、これまでの
-- BAN運用と同じくSupabase側のSQL Editorから直接announcementsテーブルに
-- insert/updateする想定(authenticatedにはselectのみ許可)。
--
-- published_at <= now() のものだけを選択させることで、published_atを
-- 未来日時にして先に書いておき、その時刻が来たら自動的に一覧へ出る
-- (=予約投稿)という運用もできるようにしてある。
--
-- 既読管理はplayer_announcement_reads(player_id, announcement_id)の
-- 中間テーブルで持つ。クライアントから直接insertできるようにし(自分の
-- 行のみ)、save_full_state等の既存RPCには一切手を入れない。
-- ============================================================================

create table if not exists public.announcements (
  id bigint generated always as identity primary key,
  title text not null,
  body text not null,
  tags jsonb not null default '[]'::jsonb,
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.announcements enable row level security;

drop policy if exists "announcements_select_published" on public.announcements;
create policy "announcements_select_published" on public.announcements
  for select using (published_at <= now());

grant select on public.announcements to authenticated;

create table if not exists public.player_announcement_reads (
  player_id uuid not null references public.players(id) on delete cascade,
  announcement_id bigint not null references public.announcements(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (player_id, announcement_id)
);

alter table public.player_announcement_reads enable row level security;

drop policy if exists "announcement_reads_select_own" on public.player_announcement_reads;
create policy "announcement_reads_select_own" on public.player_announcement_reads
  for select using (auth.uid() = player_id);

drop policy if exists "announcement_reads_insert_own" on public.player_announcement_reads;
create policy "announcement_reads_insert_own" on public.player_announcement_reads
  for insert with check (auth.uid() = player_id);

grant select, insert on public.player_announcement_reads to authenticated;
