-- ============================================================================
-- 032: 管理画面に「BANリスト」「利用制限リスト」を追加するためのRPC
-- 001〜031 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・BANリストは既存のplayers.banned_at/ban_reasonをそのまま一覧表示する
--     だけ(閲覧専用、解除操作は無し)なので、新しいRPCは不要。
--   ・利用制限リストは対象ユーザーへのBAN・制限時間の変更・解除を行える
--     必要があるため、admin_set_penaltyを新設する。
--     - p_hoursがnull or 0以下 → 解除(penalty_until/penalty_reasonをnullに)
--     - p_hoursが正の値 → 今から指定時間後を新たな期限として設定し直す
--       (延長ではなく上書き。既存のadmin_report_actionのペナルティ処理と
--       同じ考え方)
--     - BANへの切り替えは既存のadmin_set_ban(016)をそのまま使う。
-- ============================================================================

create or replace function public.admin_set_penalty(
  p_target_id uuid,
  p_hours integer default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  if p_hours is null or p_hours <= 0 then
    update public.players
      set penalty_until = null, penalty_reason = null
      where id = p_target_id;
  else
    update public.players
      set penalty_until = now() + (p_hours || ' hours')::interval,
          penalty_reason = p_reason
      where id = p_target_id;
  end if;
end;
$$;

grant execute on function public.admin_set_penalty to authenticated;
