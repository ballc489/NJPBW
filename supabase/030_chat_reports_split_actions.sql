-- ============================================================================
-- 030: 通報対応を「対象ユーザーへの対応」「通報者への対応」の2軸に分離
-- 001〜029 の後に、SQL Editorで実行してください。
--
-- 経緯:
--   029のadmin_resolve_reportは7択の中から1つを選ぶと同時にクローズも
--   してしまう設計だったが、実際の運用では対象ユーザーへの対応と
--   通報者への対応を両方行いたいケースがある(例: 対象をBANしつつ、
--   通報内容が的確だったことを踏まえ特に何もしない、あるいは逆に
--   通報者側にも問題があり両方に対応する、など)。そのため
--   ・対象ユーザーへの対応(BAN/ペナルティ/警告) … 1回選んだら固定
--   ・通報者への対応(警告/ペナルティ/BAN) … 1回選んだら固定
--   の2つを独立した選択肢とし、どちらを実行してもクローズはされない
--   ようにする。クローズは別ボタンとして常に実行可能にし、押した時だけ
--   通報がクローズされる。
--
-- 仕様の要点:
--   ・chat_reportsに対象ユーザー側・通報者側それぞれの対応状況を
--     個別のカラムで保持する(reported_action/reporter_action、
--     実行者・実行日時も個別に記録)。
--   ・admin_resolve_report(7択+クローズを1本化していた旧RPC)は廃止し、
--     admin_report_action(対象ユーザー側 or 通報者側のいずれかに対応)と
--     admin_close_report(クローズ専用)の2つに分割する。
--   ・投稿削除(p_delete_message)は上記どちらの呼び出しでも指定でき、
--     複数回指定されても実害が無いようにする(message_idは初回削除時に
--     ON DELETE SET NULLで既にnullになっているため、2回目以降は
--     「対象の投稿が既に無い」状態になり自然と何もしない)。
--   ・個人宛てお知らせ(警告)に送信元(sender_name)を追加する。今回の
--     通報対応による警告では固定で「運営」を入れるが、将来キャンペーン等
--     での個人宛てお知らせも見据え、厳密な一意値ではなく自由記述の
--     テキスト列として持たせる。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- announcements: 送信元表記
-- ----------------------------------------------------------------------------
alter table public.announcements
  add column if not exists sender_name text;

-- ----------------------------------------------------------------------------
-- chat_reports: 対象ユーザー側・通報者側を個別カラムに分離
-- ----------------------------------------------------------------------------
alter table public.chat_reports
  drop column if exists resolution_action;

alter table public.chat_reports
  add column if not exists reported_action text check (reported_action in ('ban','penalty','warn')),
  add column if not exists reported_action_by uuid references auth.users(id),
  add column if not exists reported_action_at timestamptz,
  add column if not exists reporter_action text check (reporter_action in ('ban','penalty','warn')),
  add column if not exists reporter_action_by uuid references auth.users(id),
  add column if not exists reporter_action_at timestamptz;

-- ----------------------------------------------------------------------------
-- admin_resolve_report(029)は廃止し、2つのRPCに分割する
-- ----------------------------------------------------------------------------
drop function if exists public.admin_resolve_report(bigint, text, boolean, integer, text);

-- ----------------------------------------------------------------------------
-- admin_report_action: 対象ユーザー側 or 通報者側、どちらか一方に対応する
-- (それぞれ1回選んだら固定。クローズは行わない)
-- ----------------------------------------------------------------------------
create or replace function public.admin_report_action(
  p_report_id bigint,
  p_side text,            -- 'reported' | 'reporter'
  p_action text,          -- 'ban' | 'penalty' | 'warn'
  p_delete_message boolean default false,
  p_penalty_hours integer default null,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_report record;
  v_target uuid;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  if p_side not in ('reported','reporter') then
    raise exception 'invalid side';
  end if;
  if p_action not in ('ban','penalty','warn') then
    raise exception 'invalid action';
  end if;

  select * into v_report from public.chat_reports where id = p_report_id for update;
  if not found then
    raise exception 'report not found';
  end if;
  if v_report.status = 'resolved' then
    raise exception 'report already closed';
  end if;

  if p_side = 'reported' then
    if v_report.reported_action is not null then
      raise exception 'reported side already handled';
    end if;
    v_target := v_report.reported_player_id;
  else
    if v_report.reporter_action is not null then
      raise exception 'reporter side already handled';
    end if;
    v_target := v_report.reporter_id;
  end if;

  if v_target is not null then
    if p_action = 'ban' then
      update public.players set banned_at = now(), ban_reason = coalesce(p_note, '通報対応によるBAN')
        where id = v_target;
    elsif p_action = 'penalty' then
      if p_penalty_hours is null or p_penalty_hours <= 0 then
        raise exception 'penalty hours required';
      end if;
      update public.players
        set penalty_until = now() + (p_penalty_hours || ' hours')::interval,
            penalty_reason = coalesce(p_note, '通報対応による利用制限')
        where id = v_target;
    elsif p_action = 'warn' then
      update public.players set warning_count = warning_count + 1 where id = v_target;
      insert into public.announcements (title, body, tags, published_at, target_player_id, sender_name)
        values (
          '警告',
          coalesce(p_note,
            case when p_side = 'reported'
              then 'チャットへの投稿内容について、運営より警告いたします。利用規約に違反する投稿を繰り返した場合、アカウントの利用を制限することがあります。'
              else 'いただいた通報を運営で確認しましたが、妥当性が認められず、悪意のある通報(嫌がらせ)であると判断いたしました。今後このような通報を繰り返した場合、アカウントの利用を制限することがあります。'
            end
          ),
          '[]'::jsonb, now(), v_target, '運営'
        );
    end if;
  end if;

  if p_delete_message and v_report.message_id is not null then
    delete from public.chat_messages where id = v_report.message_id;
  end if;

  if p_side = 'reported' then
    update public.chat_reports
      set reported_action = p_action, reported_action_by = v_admin, reported_action_at = now(),
          message_deleted = message_deleted or p_delete_message
      where id = p_report_id;
  else
    update public.chat_reports
      set reporter_action = p_action, reporter_action_by = v_admin, reporter_action_at = now(),
          message_deleted = message_deleted or p_delete_message
      where id = p_report_id;
  end if;
end;
$$;

grant execute on function public.admin_report_action to authenticated;

-- ----------------------------------------------------------------------------
-- admin_close_report: クローズ専用。状況に関わらずいつでも実行できる
-- ----------------------------------------------------------------------------
create or replace function public.admin_close_report(
  p_report_id bigint,
  p_delete_message boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_report record;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  select * into v_report from public.chat_reports where id = p_report_id for update;
  if not found then
    raise exception 'report not found';
  end if;
  if v_report.status = 'resolved' then
    raise exception 'report already closed';
  end if;

  if p_delete_message and v_report.message_id is not null then
    delete from public.chat_messages where id = v_report.message_id;
  end if;

  update public.chat_reports
    set status = 'resolved', resolved_by = v_admin, resolved_at = now(),
        message_deleted = message_deleted or p_delete_message
    where id = p_report_id;
end;
$$;

grant execute on function public.admin_close_report to authenticated;
