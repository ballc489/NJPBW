-- ============================================================================
-- 031: お知らせの送信元編集・個別宛て新規作成(複数人指定)に対応
-- 001〜030 の後に、SQL Editorで実行してください。
--
-- 仕様の要点:
--   ・admin_upsert_announcementに送信元(p_sender_name)を追加する。新規作成時は
--     管理画面側でデフォルト「七彩の塔運営」を入れるが、この関数自体は
--     渡された値をそのまま使うだけで固定値は持たない。
--   ・新規作成時のみp_target_player_ids(uuidの配列)を渡せるようにし、
--     null/空なら従来通り全体宛て1行、値があればその人数分だけ行を
--     複製して個別に挿入する(1行=1受信者。受信側は自分宛ての行しか
--     select出来ない既存RLSのおかげで、他に誰へ送られたかはわからない)。
--   ・既存行の編集(p_idを指定した呼び出し)では宛先(target_player_id)は
--     一切変更しない。タイトル・本文・タグ・掲載日時・送信元のみ更新する。
--   ・戻り値は、個別新規作成で複数行できるケースに単一IDを返す意味が
--     無くなるため、bigintからvoidに変更する(呼び出し元は戻り値を
--     見ていないため影響なし)。戻り値の型を変えるのでdrop→再作成する。
--   ・宛先ユーザーをIDの部分一致で検索するsearch_players_by_id_prefixを
--     追加する。PostgRESTの`?id::text=ilike.*...*`のようなキャスト付き
--     フィルタはこのプロジェクトの環境では効かなかった(uuid列に対して
--     直接ilikeしようとしてoperator does not existで失敗する)ため、
--     素直にSQL側でキャストしてから検索するRPCを用意する形にした。
-- ============================================================================

drop function if exists public.admin_upsert_announcement(text, text, bigint, jsonb, timestamptz);

create or replace function public.admin_upsert_announcement(
  p_title text,
  p_body text,
  p_id bigint default null,
  p_tags jsonb default '[]'::jsonb,
  p_published_at timestamptz default now(),
  p_sender_name text default null,
  p_target_player_ids jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target_id uuid;
  v_missing_count integer;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  if p_id is not null then
    update public.announcements
      set title = p_title, body = p_body, tags = p_tags, published_at = p_published_at,
          sender_name = p_sender_name
      where id = p_id;
    return;
  end if;

  if p_target_player_ids is null or jsonb_array_length(p_target_player_ids) = 0 then
    insert into public.announcements (title, body, tags, published_at, sender_name)
    values (p_title, p_body, p_tags, p_published_at, p_sender_name);
    return;
  end if;

  select count(*) into v_missing_count
    from jsonb_array_elements_text(p_target_player_ids) as t(id)
    where not exists (select 1 from public.players where id = t.id::uuid);
  if v_missing_count > 0 then
    raise exception 'invalid target player id';
  end if;

  for v_target_id in select (t.id)::uuid from jsonb_array_elements_text(p_target_player_ids) as t(id)
  loop
    insert into public.announcements (title, body, tags, published_at, sender_name, target_player_id)
    values (p_title, p_body, p_tags, p_published_at, p_sender_name, v_target_id);
  end loop;
end;
$$;

grant execute on function public.admin_upsert_announcement to authenticated;

-- ----------------------------------------------------------------------------
-- search_players_by_id_prefix: 管理画面の宛先ユーザー検索(ID部分一致・管理者専用)
-- ----------------------------------------------------------------------------
create or replace function public.search_players_by_id_prefix(p_query text)
returns table(id uuid, name text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  if p_query is null or length(trim(p_query)) < 2 then
    return;
  end if;

  return query
    select p.id, p.name from public.players p
    where p.id::text ilike '%' || trim(p_query) || '%'
    order by p.name
    limit 10;
end;
$$;

grant execute on function public.search_players_by_id_prefix to authenticated;
