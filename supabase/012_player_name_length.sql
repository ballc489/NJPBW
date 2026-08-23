-- ============================================================================
-- 012: プレイヤー名の文字数をサーバー側でも制限
-- 001〜011 の後に、SQL Editorで実行してください。
--
-- 背景:
--   players.nameはクライアント側(入力欄のmaxlength="12")でのみ12文字に
--   制限されており、DB側には制約が無かった。直接APIを叩けば12文字を
--   超える名前を送り込めてしまう(実行系の危険は無いが、表示崩れ等の
--   軽微な迷惑行為は可能だった)ため、サーバー側にも同じ制約を追加する。
--
--   既存行に12文字を超えるものがあっても制約追加自体が失敗しないよう、
--   先にleft()で切り詰めてから制約を付ける。
-- ============================================================================

update public.players
  set name = left(name, 12)
  where char_length(name) > 12;

alter table public.players drop constraint if exists players_name_length;
alter table public.players
  add constraint players_name_length check (char_length(name) between 1 and 12);
