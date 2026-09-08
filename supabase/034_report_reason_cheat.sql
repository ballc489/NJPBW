-- ============================================================================
-- 034: 通報理由に「不正・チートの疑い」を追加
-- 001〜033 の後に、SQL Editorで実行してください。
--
-- 背景:
--   マイページからの通報(033のsubmit_user_report)が使えるようになり、
--   コロシアムやランキングで露骨に不自然な戦闘力・記録を見た際に
--   「不正・チートの疑い」として通報できるようにしたい、という要望。
--   chat_reports.reason_categoryのCHECK制約と、submit_chat_report/
--   submit_user_report両RPCのバリデーションに'cheat'を追加する
--   (それ以外はそれぞれ029・033から不変)。
-- ============================================================================

alter table public.chat_reports
  drop constraint if exists chat_reports_reason_category_check;
alter table public.chat_reports
  add constraint chat_reports_reason_category_check
  check (reason_category in ('spam','harassment','inappropriate','impersonation','cheat','other'));

create or replace function public.submit_chat_report(
  p_message_id bigint,
  p_reason_category text,
  p_reason_text text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reporter uuid := auth.uid();
  v_msg record;
  v_channel_context jsonb;
  v_author_context jsonb;
  v_report_id bigint;
begin
  if v_reporter is null then
    raise exception 'not authenticated';
  end if;
  if p_reason_category not in ('spam','harassment','inappropriate','impersonation','cheat','other') then
    raise exception 'invalid reason category';
  end if;

  select * into v_msg from public.chat_messages where id = p_message_id;
  if not found then
    raise exception 'message not found';
  end if;

  if v_msg.player_id = v_reporter then
    raise exception 'cannot report own message';
  end if;

  if exists (
    select 1 from public.chat_reports where reporter_id = v_reporter and message_id = p_message_id
  ) then
    raise exception 'already reported';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'player_name', t.player_name, 'body', t.body, 'created_at', t.created_at, 'is_target', t.id = v_msg.id
    ) order by t.created_at, t.id), '[]'::jsonb)
    into v_channel_context
  from (
    (select * from public.chat_messages
       where channel = v_msg.channel and (created_at, id) < (v_msg.created_at, v_msg.id)
       order by created_at desc, id desc limit 5)
    union all
    (select * from public.chat_messages where id = v_msg.id)
    union all
    (select * from public.chat_messages
       where channel = v_msg.channel and (created_at, id) > (v_msg.created_at, v_msg.id)
       order by created_at asc, id asc limit 5)
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object(
      'player_name', t.player_name, 'body', t.body, 'created_at', t.created_at, 'is_target', t.id = v_msg.id
    ) order by t.created_at, t.id), '[]'::jsonb)
    into v_author_context
  from (
    (select * from public.chat_messages
       where channel = v_msg.channel and player_id is not distinct from v_msg.player_id
         and (created_at, id) < (v_msg.created_at, v_msg.id)
       order by created_at desc, id desc limit 5)
    union all
    (select * from public.chat_messages where id = v_msg.id)
    union all
    (select * from public.chat_messages
       where channel = v_msg.channel and player_id is not distinct from v_msg.player_id
         and (created_at, id) > (v_msg.created_at, v_msg.id)
       order by created_at asc, id asc limit 5)
  ) t;

  insert into public.chat_reports
    (reporter_id, reported_player_id, message_id, channel, reported_body, reported_player_name,
     reason_category, reason_text, channel_context, author_context)
  values
    (v_reporter, v_msg.player_id, v_msg.id, v_msg.channel, v_msg.body, v_msg.player_name,
     p_reason_category, nullif(trim(coalesce(p_reason_text, '')), ''), v_channel_context, v_author_context)
  returning id into v_report_id;

  return v_report_id;
end;
$$;

grant execute on function public.submit_chat_report to authenticated;

create or replace function public.submit_user_report(
  p_reported_player_id uuid,
  p_reason_category text,
  p_reason_text text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reporter uuid := auth.uid();
  v_target_name text;
  v_comment text;
  v_report_id bigint;
begin
  if v_reporter is null then
    raise exception 'not authenticated';
  end if;
  if p_reason_category not in ('spam','harassment','inappropriate','impersonation','cheat','other') then
    raise exception 'invalid reason category';
  end if;
  if p_reported_player_id = v_reporter then
    raise exception 'cannot report yourself';
  end if;

  select player_name, comment into v_target_name, v_comment
    from public.player_public_profile where player_id = p_reported_player_id;
  if v_target_name is null then
    raise exception 'player not found';
  end if;

  if exists (
    select 1 from public.chat_reports
      where reporter_id = v_reporter and reported_player_id = p_reported_player_id
        and message_id is null and status = 'open'
  ) then
    raise exception 'already reported';
  end if;

  insert into public.chat_reports
    (reporter_id, reported_player_id, message_id, channel, reported_body, reported_player_name,
     reason_category, reason_text, channel_context, author_context)
  values
    (v_reporter, p_reported_player_id, null, 'profile', coalesce(v_comment, ''), v_target_name,
     p_reason_category, nullif(trim(coalesce(p_reason_text, '')), ''), '[]'::jsonb, '[]'::jsonb)
  returning id into v_report_id;

  return v_report_id;
end;
$$;

grant execute on function public.submit_user_report to authenticated;
