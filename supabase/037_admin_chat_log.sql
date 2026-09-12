-- ============================================================================
-- 037: 管理画面のチャットログ閲覧機能(投稿削除RPC)
-- 001〜036 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・チャットログの閲覧自体は、既存のchat_messagesの
--     "chat_select_all"(using (true))ポリシーで管理者セッションからも
--     既に全件読み取り可能なため、閲覧用の新しいRPCやポリシーは不要。
--     取得は管理画面側で
--       .eq('channel', X).gte('created_at', 過去N日).order('created_at', {ascending:false})
--     のようにクエリするだけで、既存のidx_chat_messages_channel_created
--     (014で追加済み)がそのまま効く。
--   ・BAN/利用制限は既存のadmin_set_ban(016)・admin_set_penalty(032)を
--     プレイヤーIDに対してそのまま呼べるので、こちらも新規RPCは不要。
--     警告(個人宛てお知らせ)も既存のadmin_upsert_announcement(031)を
--     p_target_player_idsに1人だけ渡す形で流用する。
--   ・「投稿の削除」だけは、既存のadmin_report_action/admin_close_report
--     (030)がchat_reportsのレコードに紐づく形でしか投稿削除を扱えず、
--     通報を経由していない投稿(管理画面のログ一覧から直接見つけたもの)
--     には使えないため、単体で任意のchat_messagesを削除できる
--     admin_delete_chat_messageを新設する。
--   ・「警告」も同様にchat_reportsに紐づかない形で送りたいため、
--     admin_report_action(030)のwarn分岐と同じ処理(warning_countの加算+
--     個人宛てお知らせの作成)を行うadmin_warn_playerを新設する。
-- ============================================================================

create or replace function public.admin_delete_chat_message(p_message_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  delete from public.chat_messages where id = p_message_id;
end;
$$;

grant execute on function public.admin_delete_chat_message to authenticated;

create or replace function public.admin_warn_player(p_target_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  update public.players set warning_count = warning_count + 1 where id = p_target_id;
  insert into public.announcements (title, body, tags, published_at, target_player_id, sender_name)
    values (
      '警告',
      coalesce(p_note, 'チャットへの投稿内容について、運営より警告いたします。利用規約に違反する投稿を繰り返した場合、アカウントの利用を制限することがあります。'),
      '[]'::jsonb, now(), p_target_id, '運営'
    );
end;
$$;

grant execute on function public.admin_warn_player to authenticated;
