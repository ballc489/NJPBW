-- ============================================================================
-- 011: 戦闘力ランキング
-- 001〜010 の後に、SQL Editorで実行してください。
--
-- 背景:
--   ライバーごとの「戦闘力」(index.html側のcombatPower())を、他プレイヤーとも
--   比較できるランキングとして公開する。将来的に「1位限定称号」のような
--   景品を検討しているため、クライアントの自己申告をそのまま信用せず、
--   サーバー側(このマイグレーションのsync_combat_power関数)で
--   player_roster / player_inventoryという既に保存済みの権威あるデータから
--   同じ計算式を再現して戦闘力を算出し、その結果だけを書き込む。
--
--   計算式はindex.html側のcombatPower()と完全に一致させること(下記の
--   ジョブ倍率・基礎ステータス式・重み定数は、数式を変更しない限り
--   index.html側と手動で同期を保つ必要がある)。
--
--   更新頻度: 新しい定期実行の仕組みは用意しない。クライアントの
--   saveGame()が既存の保存タイミング(レベルアップ・装備変更・ジョブ
--   変更・ダンジョン探索の節目など)で呼ばれるたびに、この関数も
--   合わせて呼ばれる想定。値が変化していない場合はinsert...on conflict
--   のwhere句で書き込み自体をスキップし、無駄な更新を避ける。
--
--   書き込みは必ずこの関数(security definer)経由のみとし、
--   liver_power_rankingsテーブル自体への直接のinsert/update権限は
--   authenticatedロールに一切与えない(閲覧はresolve_colosseum_battleの
--   門番表示と同様、全員に公開する)。
-- ============================================================================

create table if not exists public.liver_power_rankings (
  player_id uuid not null references public.players(id) on delete cascade,
  liver_id text not null,
  player_name text not null,
  combat_power integer not null,
  achieved_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (player_id, liver_id)
);

create index if not exists idx_liver_power_rankings_board
  on public.liver_power_rankings (liver_id, combat_power desc, achieved_at asc);

alter table public.liver_power_rankings enable row level security;

drop policy if exists "liver_power_rankings_select_all" on public.liver_power_rankings;
create policy "liver_power_rankings_select_all"
  on public.liver_power_rankings for select
  using (true);

grant select on public.liver_power_rankings to authenticated;

-- 総合ランキング用: 1プレイヤーにつき戦闘力が最も高いライバー1体だけを残す
create or replace view public.liver_power_overall_ranking as
select distinct on (player_id)
  player_id, liver_id, player_name, combat_power, achieved_at
from public.liver_power_rankings
order by player_id, combat_power desc, achieved_at asc;

grant select on public.liver_power_overall_ranking to authenticated;

create or replace function public.sync_combat_power()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_player_name text;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select name into v_player_name from public.players where id = v_player_id;
  if v_player_name is null then
    return; -- まだplayersテーブルに行が無ければ何もしない(初回save_full_state前の想定外呼び出し対策)
  end if;

  with job_defs(job_id, hp_mult, atk_mult, def_mult, mp_mult) as (
    values
      ('tank', 1.4::numeric, 0.75::numeric, 1.5::numeric, 0.6::numeric),
      ('dps',  0.9::numeric, 1.4::numeric,  0.8::numeric, 0.5::numeric),
      ('mage', 0.75::numeric,0.8::numeric,  0.7::numeric, 2.0::numeric)
  ),
  rows as (
    select
      pr.liver_id,
      pr.job as active_job,
      coalesce(pr.job_progress, '{}'::jsonb) as job_progress,
      coalesce(wi.value, 0) as weapon_value,
      coalesce(ai.value, 0) as armor_value
    from public.player_roster pr
    left join public.player_inventory wi on wi.id = pr.equipped_weapon_id
    left join public.player_inventory ai on ai.id = pr.equipped_armor_id
    where pr.player_id = v_player_id and pr.unlocked = true
  ),
  job_levels as (
    select
      r.liver_id, r.active_job, r.weapon_value, r.armor_value,
      jd.job_id, jd.hp_mult, jd.atk_mult, jd.def_mult, jd.mp_mult,
      greatest(1, coalesce((r.job_progress->jd.job_id->>'level')::int, 1)) as level
    from rows r
    cross join job_defs jd
  ),
  job_stats as (
    select
      liver_id, active_job, weapon_value, armor_value, job_id,
      round((30 + level*8) * hp_mult) as hp_stat,
      round((5 + level*2) * atk_mult) as atk_stat,
      round((2 + level) * def_mult) as def_stat,
      round((10 + level*4) * mp_mult) as mp_stat
    from job_levels
  ),
  weighted as (
    select
      liver_id,
      sum(
        case when job_id = active_job
          then (hp_stat)*1.0 + (atk_stat + weapon_value)*3.5 + (def_stat + armor_value)*3.5 + mp_stat*0.5
          else hp_stat*0.3 + atk_stat*1.0 + def_stat*1.0 + mp_stat*0.15
        end
      ) as total
    from job_stats
    group by liver_id
  )
  insert into public.liver_power_rankings (player_id, liver_id, player_name, combat_power, achieved_at, updated_at)
  select v_player_id, w.liver_id, v_player_name, round(w.total)::integer, now(), now()
  from weighted w
  on conflict (player_id, liver_id) do update set
    player_name = excluded.player_name,
    combat_power = excluded.combat_power,
    achieved_at = case
      when public.liver_power_rankings.combat_power is distinct from excluded.combat_power
        then excluded.achieved_at
        else public.liver_power_rankings.achieved_at
      end,
    updated_at = now()
  where public.liver_power_rankings.combat_power is distinct from excluded.combat_power
     or public.liver_power_rankings.player_name is distinct from excluded.player_name;
end;
$$;

grant execute on function public.sync_combat_power to authenticated;
