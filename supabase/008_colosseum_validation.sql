-- ============================================================================
-- 008: コロシアムタワーのサーバー側検証を強化
-- 001〜007 の後に、SQL Editorで実行してください。
--
-- 背景:
--   resolve_colosseum_battle は今までp_won/p_floor/p_damage_dealt/
--   p_new_snapshot/p_new_max_hp_poolをほぼ無検証で信用しており、
--   コンソール等から直接RPCを叩けば「階を飛ばして即座に上位フロアを
--   奪う」「クールタイムを無視して連投する」「荒唐無稽なダメージ量で
--   他人の防衛記録を溶かす」「水増しした偽の門番を居座らせる」ことが
--   可能だった。戦闘そのものをサーバー側で再計算するほどの厳密さは
--   求めず、明らかにおかしい値だけを弾く軽量な追加検証を入れる。
--
-- 追加した検証(いずれもresolve_colosseum_battle内):
--   1. p_floor は自分のcolosseum_floor_right以下でなければならない
--      (階のショートカット禁止)
--   2. colosseum_last_challenge_atからCOLOSSEUM_COOLDOWN_MS(500秒、
--      クライアント側定数と同じ値)未満での連続呼び出しを拒否
--   3. 敗北時のダメージ量は門番のmax_hp_poolでクランプ(それ以上は
--      物理的にありえないため)
--   4. 勝利時に提出するp_new_max_hp_poolは、本人のplayer_roster上位
--      4体のmax_hp合計×1.3を超えたら拒否(装備ボーナス等の余裕を
--      持たせつつ、明らかな水増しは弾く)
--
-- 引数の数・型は変わらないため、関数のdropは不要でcreate or replace
-- のみで良い(005・007と同じ理由)。
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
  v_floor_right integer;
  v_last_challenge timestamptz;
  v_medals integer := 0;
  v_result jsonb;
  v_roster_top4_hp integer;
  v_max_hp_cap integer;
  v_damage integer;
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

  select colosseum_floor_right, colosseum_last_challenge_at
    into v_floor_right, v_last_challenge
    from public.players where id = v_player_id;

  -- 階のショートカット禁止: 今挑戦権がある階までしか申告できない
  if p_floor > coalesce(v_floor_right, 1) then
    raise exception 'floor not yet unlocked';
  end if;

  -- クールタイムをサーバー側でも強制する(クライアントのボタン無効化だけに頼らない)
  -- 500秒はクライアント側のCOLOSSEUM_COOLDOWN_MSと同じ値。変更する場合は両方直すこと。
  if v_last_challenge is not null and now() - v_last_challenge < interval '500 seconds' then
    raise exception 'colosseum cooldown active';
  end if;

  -- 行ロックを取りつつ現在の門番レコードを取得(無ければ新規扱い=ダミー相手だった)
  select * into v_row from public.colosseum_floors where floor = p_floor for update;

  if p_won then
    -- 提出された最大HPプールが、本人の実際のロスター(上位4体のmax_hp合計)から
    -- 大きく乖離していないか確認する(装備ボーナス等の余裕として1.3倍まで許容)。
    select coalesce(sum(max_hp), 0) into v_roster_top4_hp
      from (
        select max_hp from public.player_roster
          where player_id = v_player_id and unlocked = true
          order by max_hp desc limit 4
      ) t;
    v_max_hp_cap := greatest(round(v_roster_top4_hp * 1.3), 40);
    if coalesce(p_new_max_hp_pool, 0) > v_max_hp_cap then
      raise exception 'reported max_hp_pool exceeds plausible bound';
    end if;

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
      -- ダメージ量は門番の最大HPプールを超えられない(物理的な上限でクランプ)
      v_damage := least(p_damage_dealt, v_row.max_hp_pool);

      update public.colosseum_floors
        set hp_pool = greatest(0, hp_pool - v_damage),
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

grant execute on function public.resolve_colosseum_battle to authenticated;
