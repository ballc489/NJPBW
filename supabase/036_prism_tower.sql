-- ============================================================================
-- 036: プリズムタワー(素材ダンジョン)・マイページへのアクセサリー反映
-- 001〜035 の後に、SQL Editorで実行してください。
--
-- 内容:
--   ・プリズムタワーの「現在進行中のラン」を、七彩の塔のtower_runと同じ
--     要領でplayers.prism_runに永続化する(ページ再読み込みで再開できる
--     ようにするため。実際の踏破率/深度自体は既存のplayer_dungeon_progress
--     にdungeon_id='prism_f1'〜'prism_f10'として汎用的に乗るので、
--     こちらは新規テーブル不要)。
--   ・save_full_stateに引数p_prism_runを1つ追加するだけで、それ以外の
--     列・ロジックは035までの内容から不変。
--   ・マイページ(公開プロフィール)・コロシアムタワーの相手表示は
--     どちらもplayer_public_profile.rosterの同じスナップショットを見て
--     いるため、sync_public_profileにequipped_accessory(装着中の
--     クリスタルを含む)を1つ追加するだけで両方に反映される。
-- ============================================================================

alter table public.players
  add column if not exists prism_run jsonb;

-- ----------------------------------------------------------------------------
-- save_full_state: 035から不変の内容に、末尾でp_prism_runを追加しplayersへ
-- 保存するだけ。引数を1つ増やすと別シグネチャの関数として並存してしまう
-- (create or replaceは引数リストが完全一致した時だけ上書きする)ため、
-- 先に035までの21引数版を明示的に削除してから作り直す。
-- ----------------------------------------------------------------------------
drop function if exists public.save_full_state(
  text, integer, jsonb, jsonb, integer, integer, timestamptz, jsonb, jsonb, jsonb,
  integer, integer, jsonb, boolean, jsonb, jsonb, integer, timestamptz, jsonb, jsonb, jsonb
);

create or replace function public.save_full_state(
  p_name text,
  p_gold integer,
  p_party jsonb,
  p_home_furniture jsonb,
  p_colosseum_floor_right integer,
  p_colosseum_medals integer,
  p_colosseum_last_challenge_at timestamptz,
  p_roster jsonb,
  p_inventory jsonb,
  p_dungeons jsonb,
  p_destiny_tickets integer default 0,
  p_guaranteed_tickets integer default 0,
  p_rift_state jsonb default null,
  p_tutorial_done boolean default true,
  p_orbs jsonb default '{}'::jsonb,
  p_materials jsonb default '{}'::jsonb,
  p_stamina integer default 100,
  p_stamina_updated_at timestamptz default now(),
  p_tools jsonb default '{}'::jsonb,
  p_tower_run jsonb default null,
  p_tower_best_floor jsonb default '{}'::jsonb,
  p_prism_run jsonb default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.players where id = v_player_id and banned_at is not null) then
    raise exception 'account banned';
  end if;
  if exists (
    select 1 from public.players
      where id = v_player_id and penalty_until is not null and penalty_until > now()
  ) then
    raise exception 'account penalized';
  end if;

  insert into public.players (id, name, gold, party, home_furniture,
    colosseum_floor_right, colosseum_medals, colosseum_last_challenge_at,
    destiny_tickets, guaranteed_tickets, rift_state, tutorial_done, orbs, materials,
    stamina, stamina_updated_at, tools, tower_run, tower_best_floor, prism_run, updated_at)
  values (v_player_id, p_name, p_gold, p_party, p_home_furniture,
    p_colosseum_floor_right, p_colosseum_medals, p_colosseum_last_challenge_at,
    p_destiny_tickets, p_guaranteed_tickets, p_rift_state, p_tutorial_done,
    coalesce(p_orbs, '{}'::jsonb), coalesce(p_materials, '{}'::jsonb),
    greatest(0, least(100, p_stamina)), p_stamina_updated_at,
    coalesce(p_tools, '{}'::jsonb), p_tower_run, coalesce(p_tower_best_floor, '{}'::jsonb), p_prism_run, now())
  on conflict (id) do update set
    name = excluded.name, gold = excluded.gold, party = excluded.party,
    home_furniture = excluded.home_furniture,
    colosseum_floor_right = excluded.colosseum_floor_right,
    colosseum_medals = excluded.colosseum_medals,
    colosseum_last_challenge_at = excluded.colosseum_last_challenge_at,
    destiny_tickets = excluded.destiny_tickets,
    guaranteed_tickets = excluded.guaranteed_tickets,
    rift_state = excluded.rift_state,
    tutorial_done = excluded.tutorial_done,
    orbs = excluded.orbs,
    materials = excluded.materials,
    stamina = excluded.stamina,
    stamina_updated_at = excluded.stamina_updated_at,
    tools = excluded.tools,
    tower_run = excluded.tower_run,
    tower_best_floor = excluded.tower_best_floor,
    prism_run = excluded.prism_run,
    updated_at = now();

  delete from public.player_inventory
    where player_id = v_player_id
      and id not in (select value->>'id' from jsonb_array_elements(p_inventory));

  insert into public.player_inventory (id, player_id, item_type, name, rarity, value,
    resist_element, resist_value, weapon_type, affix, enhance_level,
    effect_type, effect_value, slot_count, slot_cost, socketed_into)
  select
    (item->>'id'),
    v_player_id,
    (item->>'item_type'),
    (item->>'name'),
    (item->>'rarity'),
    coalesce((item->>'value')::integer, 0),
    (item->>'resist_element'),
    nullif(item->>'resist_value','')::integer,
    (item->>'weapon_type'),
    (item->'affix'),
    coalesce((item->>'enhance_level')::integer, 0),
    (item->>'effect_type'),
    nullif(item->>'effect_value','')::numeric,
    nullif(item->>'slot_count','')::integer,
    nullif(item->>'slot_cost','')::integer,
    (item->>'socketed_into')
  from jsonb_array_elements(p_inventory) as item
  on conflict (id) do update set
    item_type = excluded.item_type, name = excluded.name, rarity = excluded.rarity,
    value = excluded.value, resist_element = excluded.resist_element, resist_value = excluded.resist_value,
    weapon_type = excluded.weapon_type, affix = excluded.affix, enhance_level = excluded.enhance_level,
    effect_type = excluded.effect_type, effect_value = excluded.effect_value,
    slot_count = excluded.slot_count, slot_cost = excluded.slot_cost,
    socketed_into = excluded.socketed_into;

  insert into public.player_roster (player_id, liver_id, job, level, exp, hp, max_hp, mp, max_mp,
    equipped_weapon_id, equipped_armor_id, equipped_accessory_id, loadout, unlocked, job_progress, costume, unlocked_costumes)
  select
    v_player_id,
    (r->>'liver_id'), (r->>'job'), (r->>'level')::integer, (r->>'exp')::integer,
    (r->>'hp')::integer, (r->>'max_hp')::integer, (r->>'mp')::integer, (r->>'max_mp')::integer,
    nullif(r->>'equipped_weapon_id',''), nullif(r->>'equipped_armor_id',''), nullif(r->>'equipped_accessory_id',''),
    coalesce(r->'loadout', '[]'::jsonb), (r->>'unlocked')::boolean,
    r->'job_progress',
    (r->>'costume'), coalesce(r->'unlocked_costumes', '[]'::jsonb)
  from jsonb_array_elements(p_roster) as r
  on conflict (player_id, liver_id) do update set
    job = excluded.job, level = excluded.level, exp = excluded.exp,
    hp = excluded.hp, max_hp = excluded.max_hp, mp = excluded.mp, max_mp = excluded.max_mp,
    equipped_weapon_id = excluded.equipped_weapon_id, equipped_armor_id = excluded.equipped_armor_id,
    equipped_accessory_id = excluded.equipped_accessory_id,
    loadout = excluded.loadout, unlocked = excluded.unlocked, job_progress = excluded.job_progress,
    costume = excluded.costume, unlocked_costumes = excluded.unlocked_costumes;

  insert into public.player_dungeon_progress (player_id, dungeon_id, depth, progress, cleared, boss_kill_count)
  select
    v_player_id,
    (d->>'dungeon_id'), (d->>'depth')::integer, (d->>'progress')::integer,
    (d->>'cleared')::boolean, (d->>'boss_kill_count')::integer
  from jsonb_array_elements(p_dungeons) as d
  on conflict (player_id, dungeon_id) do update set
    depth = excluded.depth, progress = excluded.progress,
    cleared = excluded.cleared, boss_kill_count = excluded.boss_kill_count;
end;
$$;

grant execute on function public.save_full_state to authenticated;

-- ----------------------------------------------------------------------------
-- sync_public_profile: 033から不変の内容に、equipped_accessory(装着中の
-- クリスタル配列を含む)を1つ追加するだけ。マイページとコロシアムタワーの
-- 相手表示は両方ともこのroster jsonbを見ているため、これだけで両方に効く。
-- ----------------------------------------------------------------------------
create or replace function public.sync_public_profile()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_player_name text;
  v_colosseum_best integer;
  v_party_size integer;
  v_character_count integer;
  v_cleared_count integer;
  v_roster jsonb;
begin
  if v_player_id is null then
    raise exception 'not authenticated';
  end if;

  select name, colosseum_best_floor, coalesce(jsonb_array_length(party), 0)
    into v_player_name, v_colosseum_best, v_party_size
    from public.players where id = v_player_id;
  if v_player_name is null then
    return; -- まだplayersテーブルに行が無ければ何もしない(sync_combat_powerと同じ割り切り)
  end if;

  select count(*) into v_character_count
    from public.player_roster where player_id = v_player_id and unlocked = true;

  select count(*) into v_cleared_count
    from public.player_dungeon_progress where player_id = v_player_id and cleared = true;

  select coalesce(jsonb_agg(jsonb_build_object(
      'liver_id', pr.liver_id,
      'job', pr.job,
      'job_progress', coalesce(pr.job_progress, '{}'::jsonb),
      'hp', pr.hp, 'max_hp', pr.max_hp, 'mp', pr.mp, 'max_mp', pr.max_mp,
      'costume', pr.costume,
      'unlocked_costumes', coalesce(pr.unlocked_costumes, '[]'::jsonb),
      'equipped_weapon', case when wi.id is null then null else jsonb_build_object(
        'id', wi.id, 'type', wi.item_type, 'name', wi.name, 'rarity', wi.rarity, 'rarityLabel', wi.rarity,
        'value', wi.value,
        'resist', case when wi.resist_element is not null
          then jsonb_build_object('element', wi.resist_element, 'value', wi.resist_value) else null end,
        'weaponType', wi.weapon_type, 'affix', wi.affix, 'enhanceLevel', wi.enhance_level
      ) end,
      'equipped_armor', case when ai.id is null then null else jsonb_build_object(
        'id', ai.id, 'type', ai.item_type, 'name', ai.name, 'rarity', ai.rarity, 'rarityLabel', ai.rarity,
        'value', ai.value,
        'resist', case when ai.resist_element is not null
          then jsonb_build_object('element', ai.resist_element, 'value', ai.resist_value) else null end,
        'weaponType', ai.weapon_type, 'affix', ai.affix, 'enhanceLevel', ai.enhance_level
      ) end,
      'equipped_accessory', case when acc.id is null then null else jsonb_build_object(
        'id', acc.id, 'type', acc.item_type, 'name', acc.name, 'rarity', acc.rarity, 'rarityLabel', acc.rarity,
        'mainEffect', jsonb_build_object('type', acc.effect_type, 'value', acc.effect_value),
        'slotCount', acc.slot_count,
        'crystals', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', cr.id, 'name', cr.name, 'rarity', cr.rarity, 'rarityLabel', cr.rarity,
            'effect', jsonb_build_object('type', cr.effect_type, 'value', cr.effect_value),
            'slotCost', cr.slot_cost
          ))
          from public.player_inventory cr where cr.socketed_into = acc.id
        ), '[]'::jsonb)
      ) end
    ) order by pr.liver_id), '[]'::jsonb)
    into v_roster
  from public.player_roster pr
  left join public.player_inventory wi on wi.id = pr.equipped_weapon_id
  left join public.player_inventory ai on ai.id = pr.equipped_armor_id
  left join public.player_inventory acc on acc.id = pr.equipped_accessory_id
  where pr.player_id = v_player_id and pr.unlocked = true;

  insert into public.player_public_profile
    (player_id, player_name, character_count, cleared_stage_count, colosseum_best_floor, party_size, roster, updated_at)
  values
    (v_player_id, v_player_name, v_character_count, v_cleared_count, coalesce(v_colosseum_best, 1), coalesce(v_party_size, 0), v_roster, now())
  on conflict (player_id) do update set
    player_name = excluded.player_name,
    character_count = excluded.character_count,
    cleared_stage_count = excluded.cleared_stage_count,
    colosseum_best_floor = excluded.colosseum_best_floor,
    party_size = excluded.party_size,
    roster = excluded.roster,
    updated_at = now();
end;
$$;

grant execute on function public.sync_public_profile to authenticated;
