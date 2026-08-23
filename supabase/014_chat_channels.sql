-- ============================================================================
-- 014: グローバルチャットにチャンネル(総合/攻略/雑談)を追加
-- 001〜013 の後に、SQL Editorで実行してください。
--
-- 既存のchat_messagesテーブルに channel 列を追加するだけで、テーブル・
-- RLSポリシー・Realtime購読の構成自体は変えない(1テーブルをクライアント
-- 側でchannel列によりフィルタするだけなので、追加のテーブルやRealtime
-- 購読を増やす必要が無く、サーバー負荷はほぼ増えない)。
--
-- 許可するチャンネルはDB側のcheck制約でも縛っておく(general/strategy/
-- casual = 総合/攻略/雑談。index.html側のCHAT_CHANNEL_DEFSと対応)。
-- ============================================================================

alter table public.chat_messages
  add column if not exists channel text not null default 'general';

alter table public.chat_messages drop constraint if exists chat_messages_channel_check;
alter table public.chat_messages
  add constraint chat_messages_channel_check check (channel in ('general', 'strategy', 'casual'));

create index if not exists idx_chat_messages_channel_created
  on public.chat_messages (channel, created_at);
