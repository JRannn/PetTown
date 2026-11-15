begin;
select pg_advisory_xact_lock(724881,1);
-- PetTown online v12. Run the generated online_install.sql in Supabase SQL Editor.
-- Only public.pet_online(jsonb) is exposed. All tables and helpers are private.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists pet_private;
revoke all on schema pet_private from public, anon, authenticated;

create table if not exists pet_private.config (id boolean primary key default true check(id), data jsonb not null);
alter table pet_private.config enable row level security;
create table if not exists pet_private.accounts (
 id uuid primary key default gen_random_uuid(), username text not null,
 normalized_name text not null unique, code bigint not null unique,
 password_hash text not null, device_group text not null unique,
 save_id text not null unique, payload jsonb not null, materials jsonb not null default '{}',
 revision bigint not null default 1, last_seen timestamptz not null default now(), created_at timestamptz not null default now()
);
alter table pet_private.accounts enable row level security;
-- 玩家公开编号为随机五位数；账号 UUID 以及好友、队伍关联保持不变。
alter table pet_private.accounts alter column code drop identity if exists;
create or replace function pet_private.allocate_player_code() returns bigint language plpgsql set search_path='' as $$
declare candidate bigint; attempt integer;
begin
 perform pg_advisory_xact_lock(724881,1);
 for attempt in 1..64 loop
  candidate:=10000+floor(random()*90000)::bigint;
  if not exists(select 1 from pet_private.accounts where code=candidate) then return candidate; end if;
 end loop;
 -- 接近满号时从剩余号码中随机抽取，避免反复碰撞或无限循环。
 select number into candidate from generate_series(10000,99999) number
 where not exists(select 1 from pet_private.accounts where code=number) order by random() limit 1;
 if candidate is null then raise exception '玩家编号已用完，暂时无法注册新账号。'; end if;
 return candidate;
end $$;
alter table pet_private.accounts alter column code set default pet_private.allocate_player_code();
do $$
declare account_row record;
begin
 for account_row in select id from pet_private.accounts where code is null or code not between 10000 and 99999 loop
  update pet_private.accounts set code=pet_private.allocate_player_code() where id=account_row.id;
 end loop;
 if not exists(select 1 from pg_constraint where conrelid='pet_private.accounts'::regclass and conname='pet_player_code_five_digits') then
  alter table pet_private.accounts add constraint pet_player_code_five_digits check(code between 10000 and 99999);
 end if;
end $$;
create table if not exists pet_private.sessions (
 token_hash text primary key, account_id uuid not null references pet_private.accounts(id) on delete cascade,
 expires_at timestamptz not null default(now()+interval '30 days')
);
alter table pet_private.sessions enable row level security;
create table if not exists pet_private.rate_limits (key text primary key, count integer not null default 1, resets_at timestamptz not null);
alter table pet_private.rate_limits enable row level security;
create table if not exists pet_private.friend_requests (
 sender uuid references pet_private.accounts(id), recipient uuid references pet_private.accounts(id),
 state text not null default 'pending', updated_at timestamptz not null default now(), primary key(sender,recipient), check(sender<>recipient)
);
alter table pet_private.friend_requests enable row level security;
create table if not exists pet_private.friends (
 a uuid references pet_private.accounts(id), b uuid references pet_private.accounts(id), primary key(a,b), check(a<b)
);
alter table pet_private.friends enable row level security;
create table if not exists pet_private.rooms (
 id uuid primary key default gen_random_uuid(), code bigint generated always as identity(start with 302001) unique,
 host uuid not null references pet_private.accounts(id), place text not null, day date not null,
 state text not null default 'open', created_at timestamptz not null default now(),
 ends_at bigint, deadline bigint not null, expires_at timestamptz not null default(now()+interval '15 minutes')
);
alter table pet_private.rooms enable row level security;
alter table pet_private.rooms alter column expires_at drop default;
alter table pet_private.rooms alter column expires_at drop not null;
update pet_private.rooms set expires_at=null where state='open';
create table if not exists pet_private.members (
 room_id uuid references pet_private.rooms(id), account_id uuid references pet_private.accounts(id),
 pet_id text not null, ready boolean not null default false, ready_until timestamptz,
 active boolean not null default true, claimed boolean not null default false,
 joined_at timestamptz not null default now(), result jsonb, primary key(room_id,account_id)
);
alter table pet_private.members enable row level security;
update pet_private.members set ready_until=null where ready_until is not null;
-- 升级旧版本：只替换索引，不删除队伍、成员或账号数据。
alter table pet_private.members add column if not exists recruiting boolean not null default false;
update pet_private.members m set recruiting=(m.active and r.state='open') from pet_private.rooms r where r.id=m.room_id;
drop index if exists pet_private.pet_one_active_room;
create unique index if not exists pet_one_recruiting_room on pet_private.members(account_id) where active and recruiting;
create table if not exists pet_private.invites (
 room_id uuid references pet_private.rooms(id), sender uuid references pet_private.accounts(id),
 recipient uuid references pet_private.accounts(id), state text not null default 'pending',
 created_at timestamptz not null default now(), primary key(room_id,recipient)
);
alter table pet_private.invites enable row level security;
create table if not exists pet_private.receipts (
 account_id uuid references pet_private.accounts(id), request_id text, op text not null, result jsonb not null,
 created_at timestamptz not null default now(), primary key(account_id,request_id)
);
alter table pet_private.receipts enable row level security;
-- Defense in depth: no direct client table access, including future public defaults.
revoke all on all tables in schema pet_private from public, anon, authenticated;
revoke all on all sequences in schema pet_private from public, anon, authenticated;

-- JSON/Godot round trips may represent integers as 5.0 or 1e2. Keep fractions
-- unchanged so existing integer validation still rejects fractional counts/levels.
create or replace function pet_private.normalize_numbers(j jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare n numeric; out_value jsonb;
begin
 case jsonb_typeof(j)
 when 'number' then
  n:=j::text::numeric;
  if n=trunc(n) then return to_jsonb(trunc(n)); end if;
 when 'object' then
  select coalesce(jsonb_object_agg(key,pet_private.normalize_numbers(value)),'{}') into out_value from jsonb_each(j);
  return out_value;
 when 'array' then
  select coalesce(jsonb_agg(pet_private.normalize_numbers(value) order by position),'[]') into out_value from jsonb_array_elements(j) with ordinality t(value,position);
  return out_value;
 else null;
 end case;
 return j;
end $$;
create or replace function pet_private.freecell_valid(deck jsonb, moves jsonb) returns boolean language plpgsql set search_path='' as $$
declare piles jsonb:='[[],[],[],[],[],[],[],[],[],[],[],[],[],[],[],[]]'; step jsonb; a jsonb; b jsonb; part jsonb; card int; prior int; src int; dst int; cnt int; i int; j int; slots int; cols int; n int;
begin
 if jsonb_typeof(deck)<>'array' or jsonb_array_length(deck)<>52 or jsonb_typeof(moves)<>'array' or jsonb_array_length(moves)>10000 then return false; end if;
 if (select count(distinct value) from jsonb_array_elements(deck))<>52 then return false; end if;
 for i in 0..51 loop
  card:=(deck->>i)::int; if card<0 or card>51 then return false; end if;
  piles:=jsonb_set(piles,array[(i%8)::text],(piles->(i%8))||jsonb_build_array(card));
 end loop;
 for step in select * from jsonb_array_elements(moves) loop
  if jsonb_typeof(step)<>'array' or jsonb_array_length(step)<>3 then return false; end if;
  src:=(step->>0)::int; dst:=(step->>1)::int; cnt:=(step->>2)::int;
  if src<0 or src>=12 or dst<0 or dst>=16 or src=dst or cnt<1 then return false; end if;
  a:=piles->src; b:=piles->dst; n:=jsonb_array_length(a);
  if cnt>n or (src>=8 and cnt<>1) then return false; end if;
  for i in n-cnt+1..n-1 loop
   prior:=(a->>(i-1))::int; card:=(a->>i)::int;
   if prior%13<>card%13+1 or (prior/13)%2=(card/13)%2 then return false; end if;
  end loop;
  card:=(a->>(n-cnt))::int;
  if dst>=12 then
   if cnt<>1 or card/13<>dst-12 or card%13<>jsonb_array_length(b) then return false; end if;
  elsif dst>=8 then
   if cnt<>1 or jsonb_array_length(b)<>0 then return false; end if;
  else
   if jsonb_array_length(b)>0 then
    prior:=(b->>(jsonb_array_length(b)-1))::int;
    if prior%13<>card%13+1 or (prior/13)%2=(card/13)%2 then return false; end if;
   end if;
   slots:=0; cols:=0;
   for j in 8..11 loop if jsonb_array_length(piles->j)=0 then slots:=slots+1; end if; end loop;
   for j in 0..7 loop if j<>dst and jsonb_array_length(piles->j)=0 then cols:=cols+1; end if; end loop;
   if cnt>(slots+1)*(1<<cols) then return false; end if;
  end if;
  select coalesce(jsonb_agg(value order by ord),'[]') into part from jsonb_array_elements(a) with ordinality t(value,ord) where ord>n-cnt;
  select coalesce(jsonb_agg(value order by ord),'[]') into a from jsonb_array_elements(a) with ordinality t(value,ord) where ord<=n-cnt;
  piles:=jsonb_set(jsonb_set(piles,array[src::text],a),array[dst::text],b||part);
 end loop;
 for i in 12..15 loop if jsonb_array_length(piles->i)<>13 then return false; end if; end loop;
 return true;
end $$;
create or replace function pet_private.collect_pets(s jsonb) returns jsonb language plpgsql set search_path='' as $$
declare id text; p jsonb; active text;
begin
 for id,p in select * from jsonb_each(coalesce(s->'pets','{}')) loop
  if coalesce((p->>'level')::int,1)>=9 or coalesce((p->>'collected')::boolean,false) then
   p:=p||jsonb_build_object('collected',true,'collected_at',coalesce(nullif((p->>'collected_at')::bigint,0),extract(epoch from now())::bigint));
   if not(p ? 'town_visible') then p:=p||jsonb_build_object('town_visible',false); end if;
   if coalesce(p->'action'->>'type','') not in ('reserved','expedition') then p:=jsonb_set(p,'{action}','{}'); end if;
   s:=jsonb_set(s,array['pets',id],p);
  end if;
 end loop;
 active:=s->>'active_pet_id';
 if s->'pets'->active is null or coalesce((s->'pets'->active->>'collected')::boolean,false) then
  select key into active from jsonb_each(s->'pets') where not coalesce((value->>'collected')::boolean,false) order by key limit 1;
  s:=jsonb_set(s,'{active_pet_id}',to_jsonb(coalesce(active,'')));
 end if;
 return s;
end $$;
create or replace function pet_private.clean_save(s jsonb) returns jsonb language plpgsql set search_path='' as $$
declare c jsonb; k text; p jsonb; v jsonb;
begin
 s:=pet_private.normalize_numbers(s);
 select pet_private.normalize_numbers(data) into c from pet_private.config where id;
 if jsonb_typeof(s)<>'object' or jsonb_typeof(s->'pets')<>'object' or jsonb_typeof(s->'trainer')<>'object'
 or public.jsonb_object_length_safe(s->'pets')>100 then raise exception '存档格式不正确。'; end if;
 if octet_length(s::text)>6000000 then raise exception '存档过大，请减少头像大小。'; end if;
 if s->'pets'='{}'::jsonb then raise exception '存档没有宠物。'; end if;
 for k in select jsonb_object_keys(c->'game'->'materials') loop
  s := s #- array['trainer','items',k];
 end loop;
 for k,p in select * from jsonb_each(s->'pets') loop
  if not(c->'game'->'species' ? (p->>'species')) then raise exception '宠物品种不正确。'; end if;
  if coalesce((p->>'level')::int,0) not between 1 and 9 then raise exception '宠物等级不正确。'; end if;
  for v in select value from jsonb_each(coalesce(p->'skills','{}')) loop
   if (v::text)::numeric not between 0 and 3 then raise exception '宠物技能等级不正确。'; end if;
  end loop;
 end loop;
 return pet_private.collect_pets(s);
end $$;
-- PostgreSQL has jsonb_object_keys, but no built-in jsonb_object_length.
create or replace function public.jsonb_object_length_safe(j jsonb) returns int language sql immutable set search_path='' as $$
 select count(*)::int from jsonb_object_keys(case when jsonb_typeof(j)='object' then j else '{}'::jsonb end)
$$;
-- clean_save uses the qualified helper after installation (no exposed helper grant).
create or replace function pet_private.public_profile(a pet_private.accounts) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',a.id,'username',a.username,'code',a.code::text,
 'online',a.last_seen>now()-interval '45 seconds',
 'trainer',jsonb_build_object('name',a.payload->'trainer'->>'name','level',a.payload->'trainer'->'level','avatar_png',a.payload->'trainer'->>'avatar_png'),
 'pet',coalesce((a.payload->'pets'->(a.payload->>'active_pet_id')) - 'letters' - 'skill_exp','{}'::jsonb))
$$;
-- Original plugin rules.py: skill experience (not skill levels) contributes to power.
create or replace function pet_private.battle_power(p jsonb) returns int language sql immutable set search_path='' as $$
 select coalesce((p->>'level')::int,1)*5 + coalesce((p->>'hp')::int,100)/5
 + coalesce((p->>'mood')::int,100)/10 + coalesce((p->>'hunger')::int,100)/10
 + coalesce((p->>'clean')::int,100)/15
 + coalesce((select sum(value::text::int)::int from jsonb_each(coalesce(p->'skill_exp','{}'))),0)
$$;
-- Award social experience using the web game's existing level thresholds.
create or replace function pet_private.social_exp(s jsonb, pid text, gain int, trainer_gain int, game jsonb) returns jsonb language plpgsql set search_path='' as $$
declare p jsonb:=s->'pets'->pid; lv int; xp int;
begin
 lv:=coalesce((p->>'level')::int,1); xp:=coalesce((p->>'exp')::int,0)+gain;
 while lv<9 and xp >= (game->'level_exp'->>lv)::int loop xp:=xp-(game->'level_exp'->>lv)::int; lv:=lv+1; end loop;
 p:=p||jsonb_build_object('level',lv,'exp',case when lv=9 then least(xp,(game->'level_exp'->>9)::int) else xp end);
 s:=jsonb_set(s,array['pets',pid],p);
 lv:=coalesce((s->'trainer'->>'level')::int,1); xp:=coalesce((s->'trainer'->>'exp')::int,0)+trainer_gain;
 while lv<9 and xp>=lv*100 loop xp:=xp-lv*100; lv:=lv+1; end loop;
 s:=jsonb_set(s,'{trainer,level}',to_jsonb(lv));
 return pet_private.collect_pets(jsonb_set(s,'{trainer,exp}',to_jsonb(case when lv=9 then least(xp,900) else xp end)));
end $$;
create or replace function pet_private.daily_place(d date) returns text language sql stable set search_path='' as $$
 select key from jsonb_object_keys((select data->'expeditions' from pet_private.config where id)) key
 order by md5(d::text||':'||key) limit 1
$$;
create or replace function pet_private.clear_member(m pet_private.members, failed boolean) returns void language plpgsql set search_path='' as $$
declare s jsonb; p jsonb; letter jsonb;
begin
 select pet_private.normalize_numbers(payload) into s from pet_private.accounts where id=m.account_id;
 p:=s->'pets'->m.pet_id;
 if p->'action'->>'room_id'=m.room_id::text then
  p:=jsonb_set(p,'{action}','{}');
  if failed then
   letter:=jsonb_build_object('at',extract(epoch from now())::bigint,'title','远征失败','body','未在当天领取远征奖励，远征失败。','action','expedition','coins',0,'exp',0);
   p:=jsonb_set(p,'{letters}',coalesce(p->'letters','[]')||jsonb_build_array(letter));
  end if;
  s:=jsonb_set(s,array['pets',m.pet_id],p);
  update pet_private.accounts set payload=s,revision=revision+1 where id=m.account_id;
 end if;
end $$;
create or replace function pet_private.expire_rooms() returns void language plpgsql set search_path='' as $$
declare r pet_private.rooms; m pet_private.members; today date := (now() at time zone 'Asia/Shanghai')::date;
begin
 -- Recruiting teams and ready flags have no timeout. Carry their roster into
 -- today's destination; start still rechecks today's skills, costs and deadline.
 update pet_private.rooms set day=today,place=pet_private.daily_place(today),
 deadline=extract(epoch from ((today+1)::timestamp at time zone 'Asia/Shanghai'))::bigint
 where state='open' and day<today;
 for r in select * from pet_private.rooms where state='running' and day<today loop
  for m in select * from pet_private.members where room_id=r.id and active loop
   perform pet_private.clear_member(m,r.state='running');
  end loop;
  update pet_private.members set active=false,ready=false,recruiting=false where room_id=r.id;
  update pet_private.rooms set state=case when r.state='running' then 'failed' else 'expired' end where id=r.id;
  update pet_private.invites set state='expired' where room_id=r.id and state='pending';
 end loop;
 -- Completion is derived from server time, never a browser clock.
 for m in select mm.* from pet_private.members mm join pet_private.rooms rr on rr.id=mm.room_id
 where rr.state='running' and rr.ends_at<=extract(epoch from now())::bigint and mm.active and not mm.claimed loop
  update pet_private.accounts set payload=jsonb_set(payload,array['pets',m.pet_id,'action','completed'],'true'),revision=revision+1
  where id=m.account_id and payload->'pets'->m.pet_id->'action'->>'room_id'=m.room_id::text
  and coalesce((payload->'pets'->m.pet_id->'action'->>'completed')::boolean,false)=false;
 end loop;
end $$;
create or replace function pet_private.room_view(r pet_private.rooms) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(r)||jsonb_build_object('code',r.code::text,'members',coalesce((
 select jsonb_agg(jsonb_build_object('id',a.id,'username',a.username,'code',a.code::text,
 'pet_id',case when r.state='open' and not m.ready then a.payload->>'active_pet_id' else m.pet_id end,
 'trainer',(a.payload->'trainer') - 'items' - 'coins' - 'diamond',
 'pet',(a.payload->'pets'->case when r.state='open' and not m.ready then a.payload->>'active_pet_id' else m.pet_id end) - 'letters',
 'ready',m.ready,'claimed',m.claimed,'host',a.id=r.host) order by m.joined_at)
 from pet_private.members m join pet_private.accounts a on a.id=m.account_id where m.room_id=r.id
 ),'[]'::jsonb))
$$;
create or replace function pet_private.response(aid uuid) returns jsonb language plpgsql set search_path='' as $$
declare a pet_private.accounts; r pet_private.rooms; c jsonb; requests jsonb; invite_list jsonb; snapshot jsonb;
begin
 select * into a from pet_private.accounts where id=aid;
 select data into c from pet_private.config where id;
 select rooms.* into r from pet_private.rooms rooms join pet_private.members m on rooms.id=m.room_id where m.account_id=aid and m.active
 order by (rooms.state='open') desc,rooms.ends_at,rooms.created_at limit 1;
 select coalesce(jsonb_agg(jsonb_build_object('sender',pet_private.public_profile(other),'state',req.state)),'[]') into requests
 from pet_private.friend_requests req join pet_private.accounts other on req.sender=other.id where req.recipient=aid and req.state='pending';
 select coalesce(jsonb_agg(jsonb_build_object('room',pet_private.room_view(rooms),'sender',sender.username)),'[]') into invite_list
 from pet_private.invites i join pet_private.rooms rooms on rooms.id=i.room_id join pet_private.accounts sender on sender.id=i.sender
 where i.recipient=aid and i.state='pending' and rooms.state='open';
 snapshot:=jsonb_build_object('ok',true,'server_now',extract(epoch from now())::bigint,
 'account',jsonb_build_object('id',a.id,'username',a.username,'code',a.code::text,'save_id',a.save_id),
 'save',a.payload,'revision',a.revision,'materials',a.materials,
 'friends',coalesce((select jsonb_agg(pet_private.public_profile(other) order by other.username)
 from pet_private.friends f join pet_private.accounts other on other.id=case when f.a=aid then f.b else f.a end where f.a=aid or f.b=aid),'[]'),
 'requests',requests,'invites',invite_list,'room',case when r.id is null then '{}'::jsonb else pet_private.room_view(r) end,
 'active_rooms',coalesce((select jsonb_agg(pet_private.room_view(rooms) order by (rooms.state='open') desc,rooms.ends_at,rooms.created_at)
 from pet_private.rooms rooms join pet_private.members m on rooms.id=m.room_id where m.account_id=aid and m.active),'[]'),
 'rooms',coalesce((select jsonb_agg(pet_private.room_view(rooms)) from pet_private.rooms rooms where rooms.state='open' and
 (rooms.host=aid or exists(select 1 from pet_private.friends f where f.a=least(aid,rooms.host) and f.b=greatest(aid,rooms.host)))),'[]'),
 'history',coalesce((select jsonb_agg(jsonb_build_object('id',rooms.id,'code',rooms.code::text,'place',rooms.place,'day',rooms.day,
 'state',rooms.state,'ends_at',rooms.ends_at,'deadline',rooms.deadline,'claimed',m.claimed,'result',m.result)
 order by rooms.day desc,rooms.created_at desc,rooms.id)
 from pet_private.members m join pet_private.rooms rooms on rooms.id=m.room_id where m.account_id=aid and rooms.ends_at is not null),'[]'),
 'daily',jsonb_build_object('date',(now() at time zone 'Asia/Shanghai')::date,'place',pet_private.daily_place((now() at time zone 'Asia/Shanghai')::date),
 'config',c->'expeditions'->pet_private.daily_place((now() at time zone 'Asia/Shanghai')::date)));
 return snapshot||jsonb_build_object('state_tag',md5((snapshot-'server_now'-'save'-'revision')::text));
end $$;

create or replace function public.pet_online(p_request jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
<<rpc>>
declare
 op text:=p_request->>'op'; a pet_private.accounts; other pet_private.accounts; r pet_private.rooms; m pet_private.members;
 args jsonb:=coalesce(p_request->'args','{}'); cfg jsonb; game jsonb; expedition jsonb; s jsonb; p jsonb; incoming jsonb;
 result jsonb:='{}'; extra jsonb:='{}'; saved_result jsonb; materials jsonb:='{}'; totals jsonb:='{}'; entry jsonb; reward jsonb:='{}'; letter jsonb;
 name text; normalized text; password text; tok text; k text; picked text; pid text; request_id text:=p_request->>'request_id';
 target uuid; count_members int; n int; amount int; total_weight int; roll_value int; cursor_weight int; pet_level int; xp int; need int;
 now_ts bigint:=extract(epoch from now())::bigint; today date:=(now() at time zone 'Asia/Shanghai')::date;
 authed boolean:=false; challenger_won boolean; side int; opponent_pet jsonb; opponent_pid text; cooldown_key text; wait_seconds int;
 actor_id uuid; pet_gain int; trainer_gain int; body text; changes jsonb;
 deadline_ts bigint:=extract(epoch from (((now() at time zone 'Asia/Shanghai')::date+1)::timestamp at time zone 'Asia/Shanghai'))::bigint;
begin
 -- Serialize economy/room changes, including interactions spanning multiple accounts.
 perform pg_advisory_xact_lock(724881,1);
 if op='health' then return jsonb_build_object('ok',true,'version',12); end if;
 args:=pet_private.normalize_numbers(args);
 select pet_private.normalize_numbers(data->'game'),pet_private.normalize_numbers(data->'expeditions') into game,cfg from pet_private.config where id;
 if game is null then return jsonb_build_object('ok',false,'reason','服务器尚未安装游戏配置。'); end if;
 if op in ('register','login') then
  name:=btrim(coalesce(args->>'username','')); normalized:=lower(name); password:=coalesce(args->>'password','');
  k:='auth:'||coalesce(nullif(current_setting('request.headers',true),'')::jsonb->>'x-forwarded-for','local')||':'||normalized;
  insert into pet_private.rate_limits(key,count,resets_at) values(k,1,now()+interval '5 minutes')
   on conflict(key) do update set count=case when pet_private.rate_limits.resets_at<now() then 1 else pet_private.rate_limits.count+1 end,
   resets_at=case when pet_private.rate_limits.resets_at<now() then now()+interval '5 minutes' else pet_private.rate_limits.resets_at end returning count into n;
  if n>12 then return jsonb_build_object('ok',false,'reason','操作过于频繁，请五分钟后再试。'); end if;
 end if;
 -- Errors roll back the operation while retaining the authentication rate counter.
 begin
 if op='register' then
  if char_length(name) not between 2 and 24 or name~'[[:space:][:cntrl:]]' then raise exception '注册名需为 2–24 个字符，不能包含空白。'; end if;
  if char_length(password) not between 8 and 128 then raise exception '密码需为 8–128 个字符。'; end if;
  if char_length(coalesce(args->>'device_group',''))<24 then raise exception '本地存档组标识无效。'; end if;
  select * into a from pet_private.accounts where device_group=args->>'device_group';
  if a.id is not null then
   if a.normalized_name<>normalized or a.password_hash<>extensions.crypt(encode(extensions.digest(password,'sha256'),'hex'),a.password_hash) then
    raise exception '这组三个存档已经注册过账号，请登录已有账号。';
   end if;
  else
   if exists(select 1 from pet_private.accounts where normalized_name=normalized) then raise exception '这个注册名已经被使用。'; end if;
   s:=pet_private.clean_save(args->'save');
   for k in select jsonb_object_keys(game->'materials') loop
    amount:=coalesce((args->'save'->'trainer'->'items'->>k)::int,0);
    if amount not between 0 and 100000 then raise exception '材料数量无效。'; end if;
    if amount>0 then materials:=materials||jsonb_build_object(k,amount); end if;
   end loop;
   insert into pet_private.accounts(username,normalized_name,password_hash,device_group,save_id,payload,materials)
   values(name,normalized,extensions.crypt(encode(extensions.digest(password,'sha256'),'hex'),extensions.gen_salt('bf',10)),args->>'device_group',gen_random_uuid()::text,s,materials) returning * into a;
  end if;
 elsif op='login' then
  select * into a from pet_private.accounts where normalized_name=normalized;
  if a.id is null or a.password_hash<>extensions.crypt(encode(extensions.digest(password,'sha256'),'hex'),a.password_hash) then raise exception '账号或密码不正确。'; end if;
 end if;
 if op in ('register','login') then
  tok:=encode(extensions.gen_random_bytes(32),'hex');
  insert into pet_private.sessions(token_hash,account_id) values(encode(extensions.digest(tok,'sha256'),'hex'),a.id);
  perform pet_private.expire_rooms();
  return pet_private.response(a.id)||jsonb_build_object('token',tok);
 end if;
 -- A short-lived anonymous receipt lets a lost deletion response be retried after
 -- its account/session rows have gone, without retaining player information.
 if op='delete_account' and exists(select 1 from pet_private.rate_limits where key='deleted:'||encode(extensions.digest(coalesce(p_request->>'token','')||':'||coalesce(request_id,''),'sha256'),'hex') and resets_at>now()) then
  return jsonb_build_object('ok',true,'deleted',true);
 end if;
 select accounts.* into a from pet_private.accounts accounts join pet_private.sessions se on se.account_id=accounts.id
 where se.token_hash=encode(extensions.digest(coalesce(p_request->>'token',''),'sha256'),'hex') and se.expires_at>now();
 if a.id is null then raise exception '登录已失效，请重新登录。'; end if;
 authed:=true;
 update pet_private.accounts set last_seen=now() where id=a.id;
 perform pet_private.expire_rooms();
 select * into a from pet_private.accounts where id=a.id;
 a.payload:=pet_private.normalize_numbers(a.payload);
 a.materials:=pet_private.normalize_numbers(a.materials);
 select rooms.* into r from pet_private.rooms rooms join pet_private.members mm on mm.room_id=rooms.id where mm.account_id=a.id and mm.active
 and (nullif(args->>'room_id','') is null or rooms.id::text=args->>'room_id')
 and (op<>'claim' or rooms.state='running')
 order by (rooms.state='open') desc,rooms.ends_at,rooms.created_at limit 1;
 if op='delete_account' then
  password:=coalesce(args->>'password','');
  k:='delete:'||a.id::text;
  insert into pet_private.rate_limits(key,count,resets_at) values(k,1,now()+interval '5 minutes')
   on conflict(key) do update set count=case when pet_private.rate_limits.resets_at<now() then 1 else pet_private.rate_limits.count+1 end,
   resets_at=case when pet_private.rate_limits.resets_at<now() then now()+interval '5 minutes' else pet_private.rate_limits.resets_at end returning count into n;
  if n>5 then return jsonb_build_object('ok',false,'reason','尝试次数过多，请五分钟后再试。'); end if;
  if a.password_hash<>extensions.crypt(encode(extensions.digest(password,'sha256'),'hex'),a.password_hash) then
   return jsonb_build_object('ok',false,'reason','密码不正确，未注销账号。');
  end if;
  -- Unlock pets before removing hosted rooms or this account's memberships.
  for m in select mm.* from pet_private.members mm join pet_private.rooms rr on rr.id=mm.room_id
   where mm.active and (rr.host=a.id or mm.account_id=a.id) loop
   perform pet_private.clear_member(m,false);
   if m.account_id<>a.id then
    select pet_private.normalize_numbers(payload) into s from pet_private.accounts where id=m.account_id;
    p:=s->'pets'->m.pet_id;
    letter:=jsonb_build_object('at',now_ts,'title','远征队伍解散','body','队长注销了账号，队伍已解散，宠物已回到小镇。','action','expedition','coins',0,'exp',0);
    p:=jsonb_set(p,'{letters}',coalesce(p->'letters','[]')||jsonb_build_array(letter));
    update pet_private.accounts set payload=jsonb_set(s,array['pets',m.pet_id],p),revision=revision+1 where id=m.account_id;
   end if;
  end loop;
  delete from pet_private.invites where sender=a.id or recipient=a.id or room_id in(select id from pet_private.rooms where host=a.id);
  delete from pet_private.members where account_id=a.id or room_id in(select id from pet_private.rooms where host=a.id);
  delete from pet_private.rooms where host=a.id;
  delete from pet_private.friends where pet_private.friends.a=a.id or b=a.id;
  delete from pet_private.friend_requests where sender=a.id or recipient=a.id;
  delete from pet_private.receipts where account_id=a.id;
  delete from pet_private.rate_limits where key=k or key like 'social:%'||a.id::text||'%' or (key like 'auth:%' and right(key,length(a.normalized_name)+1)=':'||a.normalized_name);
  delete from pet_private.sessions where account_id=a.id;
  insert into pet_private.rate_limits(key,count,resets_at) values('deleted:'||encode(extensions.digest(coalesce(p_request->>'token','')||':'||coalesce(request_id,''),'sha256'),'hex'),0,now()+interval '1 day') on conflict(key) do nothing;
  delete from pet_private.accounts where id=a.id;
  return jsonb_build_object('ok',true,'deleted',true);
 elsif op='logout' then
  delete from pet_private.sessions where token_hash=encode(extensions.digest(p_request->>'token','sha256'),'hex');
  return jsonb_build_object('ok',true);
 end if;
 if op in ('material_spend','evolve','claim','battle','play_together','collection_play','freecell_win') and request_id is not null then
  select receipts.result into saved_result from pet_private.receipts where account_id=a.id and receipts.request_id=rpc.request_id;
  if saved_result is not null then return pet_private.response(a.id)||saved_result; end if;
 end if;
 if op='save' then
  if (args->>'revision')::bigint<>a.revision then return pet_private.response(a.id)||jsonb_build_object('ok',false,'conflict',true,'reason','另一处已更新存档，已恢复服务器最新进度。'); end if;
  if args->>'save_id'<>a.save_id then raise exception '这不是账号绑定的存档。'; end if;
  incoming:=pet_private.clean_save(args->'save');
  incoming:=jsonb_set(incoming,'{trainer,last_collection_play}',coalesce(a.payload->'trainer'->'last_collection_play','""'::jsonb));
  incoming:=jsonb_set(incoming,'{trainer,freecell_reward_day}',coalesce(a.payload->'trainer'->'freecell_reward_day','""'::jsonb));
  incoming:=jsonb_set(incoming,'{trainer,diamond}',coalesce(a.payload->'trainer'->'diamond','0'::jsonb));
  -- Neither a stale local save nor a different browser can replace a reserved pet.
  for m in select * from pet_private.members where account_id=a.id and active loop
   if m.ready or exists(select 1 from pet_private.rooms where id=m.room_id and state='running') then
    if incoming->'pets'->m.pet_id is distinct from a.payload->'pets'->m.pet_id then raise exception '参战宠物已锁定，请先同步远征状态。'; end if;
   end if;
   if m.ready and exists(select 1 from pet_private.rooms where id=m.room_id and state='open')
    and incoming->>'active_pet_id' is distinct from a.payload->>'active_pet_id' then raise exception '请先取消准备，再切换主宠物。'; end if;
  end loop;
  for k,p in select * from jsonb_each(incoming->'pets') loop
   if p->'action'->>'type' in ('expedition','reserved') and not exists(select 1 from pet_private.members where account_id=a.id and active and pet_id=k) then raise exception '远征状态不能由本地存档创建。'; end if;
   entry:=a.payload->'pets'->k;
   if coalesce((entry->>'collected')::boolean,false) and not coalesce((p->>'collected')::boolean,false) then raise exception '馆藏宠物不能移出收藏馆。'; end if;
   if p->'action'->>'type'='evolve' and p->'action' is distinct from entry->'action' then raise exception '进化必须通过共享仓库确认。'; end if;
   if coalesce(p->>'evolution_species','')<>coalesce(entry->>'evolution_species','') then
    if entry->'action'->>'type' is distinct from 'evolve' or coalesce((entry->'action'->>'ends_at')::bigint,now_ts+1)>now_ts
     or p->>'evolution_species' is distinct from entry->'action'->>'evolution_species' then raise exception '进化还没有完成，请同步服务器时间。'; end if;
   end if;
  end loop;
  update pet_private.accounts set payload=incoming,revision=revision+1 where id=a.id;
 elsif op='search' then
  select * into other from pet_private.accounts where normalized_name=lower(btrim(args->>'query')) or code::text=btrim(args->>'query') limit 1;
  extra:=jsonb_build_object('found',case when other.id is null then '{}'::jsonb else pet_private.public_profile(other) end);
 elsif op='profile' then
  target:=(args->>'target')::uuid;
  if target<>a.id and not exists(select 1 from pet_private.friends where pet_private.friends.a=least(a.id,target) and b=greatest(a.id,target)) then raise exception '成为好友后才能查看宠物资料。'; end if;
  select * into other from pet_private.accounts where id=target;
  extra:=jsonb_build_object('profile',pet_private.public_profile(other));
 elsif op in ('battle','play_together') then
  target:=(args->>'target')::uuid;
  if target=a.id then raise exception '要找另一位玩家的主宠物互动哦。'; end if;
  if not exists(select 1 from pet_private.friends where pet_private.friends.a=least(a.id,target) and b=greatest(a.id,target)) then raise exception '成为好友后才能互动。'; end if;
  select * into other from pet_private.accounts where id=target;
  pid:=a.payload->>'active_pet_id'; p:=a.payload->'pets'->pid;
  other.payload:=pet_private.normalize_numbers(other.payload);
  opponent_pid:=other.payload->>'active_pet_id'; opponent_pet:=other.payload->'pets'->opponent_pid;
  if p is null or opponent_pet is null then raise exception '双方都需要有主宠物才能互动。'; end if;
  for entry in select value from jsonb_array_elements(jsonb_build_array(p,opponent_pet)) loop
   if coalesce((entry->>'collected')::boolean,false) then raise exception '馆藏宠物不能参加普通互动。'; end if;
   if coalesce(entry->'action','{}')<>'{}'::jsonb then raise exception '%正在忙，请空闲后再来。',entry->>'name'; end if;
   for k in select unnest(array['hp','hunger','mood','clean']) loop
    if coalesce((entry->>k)::int,100)<=0 then raise exception '%的属性为0，需要先恢复。',entry->>'name'; end if;
   end loop;
   if op='battle' and coalesce((entry->>'hp')::int,100)<10 then raise exception '%体力不足10，不能切磋。',entry->>'name'; end if;
  end loop;
  cooldown_key:='social:'||op||':'||least(a.id,target)::text||':'||greatest(a.id,target)::text;
  select greatest(0,ceil(extract(epoch from resets_at-now()))::int) into wait_seconds from pet_private.rate_limits where key=cooldown_key;
  if wait_seconds>0 then raise exception '这两只宠物刚%过啦，还要等%小时%分钟。',case when op='battle' then '切磋' else '玩' end,wait_seconds/3600,ceil((wait_seconds%3600)/60.0)::int; end if;
  if op='battle' then
   challenger_won:=pet_private.battle_power(p)+floor(random()*30)::int+1 >= pet_private.battle_power(opponent_pet)+floor(random()*30)::int+1;
   body:='【'||(p->>'name')||'】向【'||(opponent_pet->>'name')||'】发起切磋！'||chr(10)||'【'||case when challenger_won then p->>'name' else opponent_pet->>'name' end||'】赢下了切磋！';
  else
   body:='【'||(p->>'name')||'】和【'||(opponent_pet->>'name')||'】一起玩了一会儿。';
  end if;
  for side in 0..1 loop
   actor_id:=case when side=0 then a.id else other.id end;
   s:=case when side=0 then a.payload else other.payload end;
   pid:=s->>'active_pet_id'; p:=s->'pets'->pid;
   if op='battle' then
    pet_gain:=case when (side=0)=challenger_won then 10 else 5 end;
    trainer_gain:=case when (side=0)=challenger_won then 8 else 5 end;
    p:=p||jsonb_build_object('battle_count',coalesce((p->>'battle_count')::int,0)+1,'battle_win',coalesce((p->>'battle_win')::int,0)+case when (side=0)=challenger_won then 1 else 0 end,
     'hp',greatest(0,(p->>'hp')::int-10),'mood',greatest(0,(p->>'mood')::int-3));
   else
    pet_gain:=5; trainer_gain:=2;
    p:=p||jsonb_build_object('hp',greatest(0,(p->>'hp')::int-5),'mood',least(coalesce((game->'species'->(p->>'species')->'base'->>'mood')::int,100),(p->>'mood')::int+5));
   end if;
   changes:=coalesce(game->'tendency_rules'->case when op='battle' then 'battle' else 'play_together' end,'{}');
   if op='battle' and side=1 and not challenger_won then changes:=changes||jsonb_build_object('好运',coalesce((changes->>'好运')::int,0)+coalesce((game->'tendency_rules'->'battle_defender_win'->>'好运')::int,0)); end if;
   p:=jsonb_set(p,'{tendency}',coalesce(p->'tendency','{}'));
   for k,entry in select * from jsonb_each(changes) loop p:=jsonb_set(p,array['tendency',k],to_jsonb(greatest(0,coalesce((p->'tendency'->>k)::int,0)+entry::text::int))); end loop;
   letter:=jsonb_build_object('at',now_ts,'title',case when op='battle' then '好友切磋' else '一起玩耍' end,
    'body',body||chr(10)||case when op='battle' then '体力 -10，心情 -3。' else '心情 +5，体力 -5。' end||'宠物经验 +'||pet_gain||'，饲主经验 +'||trainer_gain||'。',
    'action',op,'coins',0,'exp',pet_gain);
   p:=p||jsonb_build_object('updated_at',now_ts,'letters',coalesce(p->'letters','[]')||jsonb_build_array(letter));
   s:=pet_private.social_exp(jsonb_set(s,array['pets',pid],p),pid,pet_gain,trainer_gain,game);
   update pet_private.accounts set payload=s,revision=revision+1 where id=actor_id;
   if side=0 then extra:=jsonb_build_object('summary',letter->>'body','letter',letter,'won',challenger_won); end if;
  end loop;
  insert into pet_private.rate_limits(key,count,resets_at) values(cooldown_key,1,now()+make_interval(secs=>case when op='battle' then 14400 else 7200 end))
   on conflict(key) do update set resets_at=excluded.resets_at;
  select * into other from pet_private.accounts where id=target;
  extra:=extra||jsonb_build_object('profile',pet_private.public_profile(other));
 elsif op='freecell_win' then
  if not coalesce(pet_private.freecell_valid(args->'deck',args->'moves'),false) then raise exception '牌局校验失败，请重新打开牌局后重试。'; end if;
  k:=md5(jsonb_build_array(args->'deck',args->'moves')::text);
  amount:=0;
  if not exists(select 1 from pet_private.receipts where account_id=a.id and receipts.op='freecell_win' and receipts.result->>'game_hash'=k) then
   amount:=case when a.payload->'trainer'->>'freecell_reward_day'=today::text then 0 else 3 end;
   s:=jsonb_set(a.payload,'{trainer,diamond}',to_jsonb(coalesce((a.payload->'trainer'->>'diamond')::int,0)+amount));
   s:=jsonb_set(s,'{trainer,freecell_reward_day}',to_jsonb(today::text));
   update pet_private.accounts set payload=s,revision=revision+1 where id=a.id;
  end if;
  extra:=jsonb_build_object('diamonds',amount,'game_hash',k);
 elsif op='collection_play' then
  if a.payload->'trainer'->>'last_collection_play'=today::text then raise exception '今天已经进行过收藏玩耍了，明天再来吧。'; end if;
  if not exists(select 1 from jsonb_each(a.payload->'pets') where coalesce((value->>'collected')::boolean,false)) then raise exception '收藏馆里还没有宠物。'; end if;
  s:=a.payload; amount:=0; body:='';
  for pid,p in select * from jsonb_each(s->'pets') where coalesce((value->>'collected')::boolean,false) order by key loop
   exit when amount>=30;
   if coalesce(p->'action','{}')<>'{}'::jsonb or coalesce((p->>'hp')::int,0)<=20 or coalesce((p->>'hunger')::int,0)<=0 or coalesce((p->>'mood')::int,0)<=0 or coalesce((p->>'clean')::int,0)<=0 then
    body:=body||'【'||(p->>'name')||'】暂不可玩耍，请先照顾并恢复属性。'||chr(10);
    continue;
   end if;
   n:=least(floor(random()*3)::int+1,30-amount); xp:=floor(random()*11)::int+15; need:=floor(random()*8)::int+8;
   p:=p||jsonb_build_object('hp',(p->>'hp')::int-20,'clean',greatest(0,(p->>'clean')::int-need),'mood',greatest(0,(p->>'mood')::int-xp));
   p:=jsonb_set(p,'{tendency}',coalesce(p->'tendency','{}'));
   for k,entry in select * from jsonb_each(game->'tendency_rules'->'play') loop p:=jsonb_set(p,array['tendency',k],to_jsonb(coalesce((p->'tendency'->>k)::int,0)+entry::text::int)); end loop;
   name:='心情 -'||xp||'，体力 -20，清洁 -'||need||'，钻石 +'||n||'。';
   letter:=jsonb_build_object('at',now_ts,'title','收藏玩耍','body',name,'action','collection_play','coins',0,'exp',0);
   p:=jsonb_set(p,'{letters}',coalesce(p->'letters','[]')||jsonb_build_array(letter));
   s:=jsonb_set(s,array['pets',pid],p); amount:=amount+n;
   body:=body||'【'||(p->>'name')||'】'||name||chr(10);
  end loop;
  s:=jsonb_set(s,'{trainer,diamond}',to_jsonb(coalesce((s->'trainer'->>'diamond')::int,0)+amount));
  s:=jsonb_set(s,'{trainer,last_collection_play}',to_jsonb(today::text));
  update pet_private.accounts set payload=s,revision=revision+1 where id=a.id;
  extra:=jsonb_build_object('diamonds',amount,'summary',body||'今日获得钻石：'||amount||'/30');
 elsif op='friend_request' then
  target:=(args->>'target')::uuid;
  if target=a.id then raise exception '不能添加自己。'; end if;
  if exists(select 1 from pet_private.friends where pet_private.friends.a=least(a.id,target) and b=greatest(a.id,target)) then raise exception '已经是好友了。'; end if;
  select * into other from pet_private.accounts where id=target;
  if other.id is null then raise exception '没有找到这个玩家。'; end if;
  insert into pet_private.friend_requests(sender,recipient) values(a.id,target) on conflict(sender,recipient) do update
   set state='pending',updated_at=now() where pet_private.friend_requests.state='accepted' or pet_private.friend_requests.updated_at<now()-interval '5 minutes';
 elsif op in ('friend_accept','friend_reject') then
  target:=(args->>'target')::uuid;
  if not exists(select 1 from pet_private.friend_requests where sender=target and recipient=a.id and state='pending') then raise exception '这条申请已处理。'; end if;
  if op='friend_accept' then insert into pet_private.friends(a,b) values(least(a.id,target),greatest(a.id,target)) on conflict do nothing; end if;
  update pet_private.friend_requests set state=case when op='friend_accept' then 'accepted' else 'rejected' end where sender=target and recipient=a.id;
 elsif op='friend_remove' then
  target:=(args->>'target')::uuid;
  delete from pet_private.friends where pet_private.friends.a=least(a.id,target) and b=greatest(a.id,target);
 elsif op='create' then
  if exists(select 1 from pet_private.members where account_id=a.id and active and recruiting) then raise exception '你已经参加一支未出发队伍，请先退出。'; end if;
  pid:=a.payload->>'active_pet_id'; p:=a.payload->'pets'->pid;
  if p is null or coalesce((p->>'collected')::boolean,false) then raise exception '请先选择未入馆的主宠物。'; end if;
  if coalesce(p->'action','{}')<>'{}'::jsonb then raise exception '主宠物正在忙。'; end if;
  name:=pet_private.daily_place(today); expedition:=cfg->name;
  if now_ts+(expedition->>'seconds')::int>=deadline_ts then raise exception '今天剩余时间不足以完成远征。'; end if;
  insert into pet_private.rooms(host,place,day,deadline) values(a.id,name,today,deadline_ts) returning * into r;
  insert into pet_private.members(room_id,account_id,pet_id,recruiting) values(r.id,a.id,pid,true);
  extra:=jsonb_build_object('selected_room_id',r.id);
 elsif op='join' then
  if exists(select 1 from pet_private.members where account_id=a.id and active and recruiting) then raise exception '你已经参加一支未出发队伍，请先退出。'; end if;
  select * into r from pet_private.rooms where code::text=args->>'code';
  if r.id is null or r.state<>'open' then raise exception '队伍不存在或已经出发。'; end if;
  if not exists(select 1 from pet_private.friends where pet_private.friends.a=least(a.id,r.host) and b=greatest(a.id,r.host))
   and not exists(select 1 from pet_private.invites where room_id=r.id and recipient=a.id and state='pending') then raise exception '需要队长好友关系或邀请才能加入。'; end if;
  select count(*) into n from pet_private.members where room_id=r.id and active;
  if n>=4 then raise exception '队伍已满。'; end if;
  pid:=a.payload->>'active_pet_id'; p:=a.payload->'pets'->pid;
  if p is null or coalesce((p->>'collected')::boolean,false) then raise exception '请先选择未入馆的主宠物。'; end if;
  if coalesce(p->'action','{}')<>'{}'::jsonb then raise exception '主宠物正在忙。'; end if;
  insert into pet_private.members(room_id,account_id,pet_id,active,ready,claimed,recruiting) values(r.id,a.id,pid,true,false,false,true)
   on conflict(room_id,account_id) do update set active=true,ready=false,claimed=false,recruiting=true,pet_id=excluded.pet_id,joined_at=now();
  extra:=jsonb_build_object('selected_room_id',r.id);
  update pet_private.invites set state='accepted' where room_id=r.id and recipient=a.id;
 elsif op='invite' then
  if r.id is null or r.state<>'open' then raise exception '请先创建招募中的队伍。'; end if;
  target:=(args->>'target')::uuid;
  if not exists(select 1 from pet_private.friends where pet_private.friends.a=least(a.id,target) and b=greatest(a.id,target)) then raise exception '只能邀请好友。'; end if;
  insert into pet_private.invites(room_id,sender,recipient) values(r.id,a.id,target) on conflict(room_id,recipient) do nothing;
 elsif op='invite_reject' then
  update pet_private.invites set state='rejected' where recipient=a.id and state='pending'
   and room_id in(select id from pet_private.rooms where code::text=args->>'code');
 elsif op='ready' then
  if r.id is null or r.state<>'open' then raise exception '当前没有可准备的队伍。'; end if;
  select * into m from pet_private.members where room_id=r.id and account_id=a.id;
  if m.ready then
   perform pet_private.clear_member(m,false);
   update pet_private.members set ready=false,ready_until=null where room_id=r.id and account_id=a.id;
  else
   pid:=a.payload->>'active_pet_id'; p:=a.payload->'pets'->pid; expedition:=cfg->r.place;
   if coalesce(p->'action','{}')<>'{}'::jsonb then raise exception '主宠物正在忙，请先完成活动。'; end if;
   for k,entry in select * from jsonb_each(expedition->'cost') loop
    if coalesce((p->>k)::int,0)<(entry::text)::int then raise exception '宠物的%不足。',case k when 'hp' then '体力' when 'hunger' then '饱食' when 'mood' then '心情' else '清洁' end; end if;
   end loop;
   p:=jsonb_set(p,'{action}',jsonb_build_object('type','reserved','label','远征准备','place','远征营地','room_id',r.id,'completed',false,'ends_at',0));
   update pet_private.accounts set payload=jsonb_set(payload,array['pets',pid],p),revision=revision+1 where id=a.id;
   update pet_private.members set ready=true,pet_id=pid,ready_until=null where room_id=r.id and account_id=a.id;
  end if;
 elsif op='leave' then
  if r.id is null or r.state<>'open' then raise exception '远征出发后不能退出或中断。'; end if;
  select * into m from pet_private.members where room_id=r.id and account_id=a.id;
  perform pet_private.clear_member(m,false);
  delete from pet_private.members where room_id=r.id and account_id=a.id;
  select account_id into target from pet_private.members where room_id=r.id and active order by joined_at limit 1;
  if target is null then update pet_private.rooms set state='expired' where id=r.id;
  elsif r.host=a.id then update pet_private.rooms set host=target where id=r.id; end if;
 elsif op='start' then
  if r.id is null or r.state<>'open' or r.host<>a.id then raise exception '只有招募中队伍的队长可以出发。'; end if;
  select count(*) into count_members from pet_private.members where room_id=r.id and active;
  if count_members not between 3 and 4 then raise exception '远征需要 3–4 个不同账号。'; end if;
  if exists(select 1 from pet_private.members where room_id=r.id and active and not ready) then raise exception '请等待所有队员准备。'; end if;
  expedition:=cfg->r.place;
  if now_ts+(expedition->>'seconds')::int>=r.deadline then raise exception '今天剩余时间不足，不能出发。'; end if;
  for m in select * from pet_private.members where room_id=r.id and active loop
   select pet_private.normalize_numbers(payload) into s from pet_private.accounts where id=m.account_id;
   p:=s->'pets'->m.pet_id;
   if p->'action'->>'room_id'<>r.id::text or p->'action'->>'type'<>'reserved' then raise exception '队员状态已变化，请重新准备。'; end if;
   for k,entry in select * from jsonb_each(expedition->'required_skills') loop totals:=totals||jsonb_build_object(k,coalesce((totals->>k)::int,0)+coalesce((p->'skills'->>k)::int,0)); end loop;
   for k,entry in select * from jsonb_each(expedition->'cost') loop
    if coalesce((p->>k)::int,0)<(entry::text)::int then raise exception '有队员属性不足，请重新准备。'; end if;
   end loop;
  end loop;
  for k,entry in select * from jsonb_each(expedition->'required_skills') loop if coalesce((totals->>k)::int,0)<(entry::text)::int then raise exception '全队%技能不足。',k; end if; end loop;
  for m in select * from pet_private.members where room_id=r.id and active loop
   select pet_private.normalize_numbers(payload) into s from pet_private.accounts where id=m.account_id; p:=s->'pets'->m.pet_id;
   for k,entry in select * from jsonb_each(expedition->'cost') loop p:=jsonb_set(p,array[k],to_jsonb((p->>k)::int-(entry::text)::int)); end loop;
   for k,entry in select * from jsonb_each(expedition->'tendency') loop p:=jsonb_set(p,array['tendency',k],to_jsonb(coalesce((p->'tendency'->>k)::int,0)+(entry::text)::int)); end loop;
   p:=jsonb_set(p,'{action}',jsonb_build_object('type','expedition','label',r.place||'远征','place','远征营地','room_id',r.id,'started_at',now_ts,'ends_at',now_ts+(expedition->>'seconds')::int,'duration',(expedition->>'seconds')::int,'completed',false));
   update pet_private.accounts set payload=jsonb_set(s,array['pets',m.pet_id],p),revision=revision+1 where id=m.account_id;
  end loop;
  update pet_private.rooms set state='running',ends_at=now_ts+(expedition->>'seconds')::int where id=r.id;
  update pet_private.members set recruiting=false where room_id=r.id;
  update pet_private.invites set state='expired' where room_id=r.id and state='pending';
 elsif op='claim' then
  if r.id is null or r.state<>'running' then raise exception '没有可领取的远征奖励。'; end if;
  if now_ts<r.ends_at then raise exception '远征还没有结束。'; end if;
  if now_ts>=r.deadline then raise exception '未在当天领取，远征失败。'; end if;
  select * into m from pet_private.members where room_id=r.id and account_id=a.id;
  if m.claimed then raise exception '奖励已经领取。'; end if;
  expedition:=cfg->r.place; reward:=expedition->'fixed_rewards';
  select sum((value->>'weight')::int) into total_weight from jsonb_array_elements(expedition->'random_rewards');
  roll_value:=floor(random()*total_weight)::int+1; cursor_weight:=0;
  for entry in select * from jsonb_array_elements(expedition->'random_rewards') loop
   cursor_weight:=cursor_weight+(entry->>'weight')::int;
   if roll_value<=cursor_weight then
    if entry->>'item'<>'空' then reward:=reward||jsonb_build_object(entry->>'item',coalesce((reward->>(entry->>'item'))::int,0)+(entry->>'count')::int); end if;
    exit;
   end if;
  end loop;
  s:=a.payload; p:=s->'pets'->m.pet_id;
  p:=jsonb_set(p,'{action}','{}'); xp:=coalesce((p->>'exp')::int,0)+(expedition->>'exp')::int; pet_level:=(p->>'level')::int;
  while pet_level<9 and xp >= (game->'level_exp'->>pet_level)::int loop xp:=xp-(game->'level_exp'->>pet_level)::int; pet_level:=pet_level+1; end loop;
  p:=jsonb_set(jsonb_set(p,'{level}',to_jsonb(pet_level)),'{exp}',to_jsonb(least(xp,(game->'level_exp'->>9)::int)));
  for entry in select * from jsonb_array_elements(expedition->'skill_exp'->'rolls') loop
   if random()<=(entry->>'chance')::numeric then
    n:=floor(random()*jsonb_array_length(entry->'skills'))::int; picked:=entry->'skills'->>n;
    amount:=(entry->>'min')::int+floor(random()*((entry->>'max')::int-(entry->>'min')::int+1))::int;
    n:=coalesce((p->'skills'->>picked)::int,0); xp:=coalesce((p->'skill_exp'->>picked)::int,0)+amount;
    while n<3 and xp >= (game->'skill_rules'->'need_exp'->>n)::int loop xp:=xp-(game->'skill_rules'->'need_exp'->>n)::int; n:=n+1; end loop;
    p:=jsonb_set(p,array['skills',picked],to_jsonb(n)); p:=jsonb_set(p,array['skill_exp',picked],to_jsonb(xp));
   end if;
  end loop;
  materials:=a.materials;
  name:='在'||r.place||'和伙伴们一起完成了探索。'||chr(10)||'带回金币 '||(reward->>'coin')||'，宠物经验 +'||(expedition->>'exp')||'。';
  for k,entry in select * from jsonb_each(reward) loop
   if k<>'coin' then materials:=materials||jsonb_build_object(k,coalesce((materials->>k)::int,0)+(entry::text)::int); name:=name||chr(10)||k||' ×'||entry::text; end if;
  end loop;
  letter:=jsonb_build_object('at',now_ts,'title',r.place||'远征','body',name,'action','expedition','place',r.place,'pet_id',m.pet_id,'name',p->>'name','coins',(reward->>'coin')::int,'exp',(expedition->>'exp')::int);
  p:=jsonb_set(p,'{letters}',coalesce(p->'letters','[]')||jsonb_build_array(letter));
  s:=jsonb_set(s,array['pets',m.pet_id],p); s:=jsonb_set(s,'{trainer,coins}',to_jsonb(coalesce((s->'trainer'->>'coins')::bigint,0)+(reward->>'coin')::int));
  update pet_private.accounts set payload=pet_private.collect_pets(s),materials=materials,revision=revision+1 where id=a.id;
  extra:=jsonb_build_object('summary',name,'letter',letter,'reward',reward);
  update pet_private.members set claimed=true,active=false,ready=false,recruiting=false,result=extra where room_id=r.id and account_id=a.id;
  if not exists(select 1 from pet_private.members where room_id=r.id and active) then update pet_private.rooms set state='claimed' where id=r.id; end if;
 elsif op='material_spend' then
  k:=args->>'material';
  if not(game->'materials' ? k) or coalesce((a.materials->>k)::int,0)<1 then raise exception '共享仓库中没有这个材料。'; end if;
  update pet_private.accounts set materials=jsonb_set(a.materials,array[k],to_jsonb((a.materials->>k)::int-1)) where id=a.id;
  extra:=jsonb_build_object('spent',k,'receipt',request_id);
 elsif op='evolve' then
  pid:=args->>'pet_id'; k:=args->>'material'; s:=a.payload; p:=s->'pets'->pid;
  if coalesce((p->>'collected')::boolean,false) then raise exception '收藏馆宠物不能进化。'; end if;
  if p is null or coalesce(p->'action','{}')<>'{}'::jsonb then raise exception '宠物不存在或正在忙。'; end if;
  if (p->>'level')::int<5 or coalesce(p->>'evolution_species','')<>'' then raise exception '宠物需达到五级并且尚未进化。'; end if;
  picked:='温顺'; for name in select unnest(array['温顺','冒险','好运']) loop if coalesce((p->'tendency'->>name)::int,0)>coalesce((p->'tendency'->>picked)::int,0) then picked:=name; end if; end loop;
  if game->'materials'->k->>'tendency' is distinct from picked then raise exception '%不喜欢这个材料哦。',p->>'name'; end if;
  if coalesce((a.materials->>k)::int,0)<1 then raise exception '共享仓库中没有这个材料。'; end if;
  if (s->'trainer'->>'coins')::int<520 then raise exception '进化需要 520 金币。'; end if;
  entry:=game->'species'->(p->>'species')->'forms'->picked;
  if coalesce(jsonb_array_length(entry),0)=0 then raise exception '暂时没有可进化品种。'; end if;
  name:=entry->>floor(random()*jsonb_array_length(entry))::int;
  p:=jsonb_set(p,'{action}',jsonb_build_object('type','evolve','label','进化','place','','started_at',now_ts,'ends_at',now_ts+28800,'duration',28800,'completed',false,'evolution_species',name));
  s:=jsonb_set(s,array['pets',pid],p); s:=jsonb_set(s,'{trainer,coins}',to_jsonb((s->'trainer'->>'coins')::int-520));
  update pet_private.accounts set payload=s,materials=jsonb_set(a.materials,array[k],to_jsonb((a.materials->>k)::int-1)),revision=revision+1 where id=a.id;
 elsif op='poll' then
  result:=pet_private.response(a.id);
  if args->>'state_tag'=result->>'state_tag' and coalesce((args->>'revision')::bigint,-1)=(result->>'revision')::bigint then
   return jsonb_build_object('ok',true,'unchanged',true,'revision',result->'revision','state_tag',result->'state_tag','server_now',now_ts);
  end if;
  return result;
 elsif op<>'sync' then raise exception '不支持的联机操作。';
 end if;
 if op in ('material_spend','evolve','claim','battle','play_together','collection_play','freecell_win') then
  if request_id is null or char_length(request_id)<16 then raise exception '缺少幂等请求编号。'; end if;
  insert into pet_private.receipts(account_id,request_id,op,result) values(a.id,request_id,op,extra);
 end if;
 result:=pet_private.response(a.id)||extra;
 if op='save' and coalesce((args->>'compact')::boolean,false) then
  return jsonb_build_object('ok',true,'revision',result->'revision','state_tag',result->'state_tag','server_now',now_ts);
 end if;
 return result;
 exception when unique_violation then return jsonb_build_object('ok',false,'reason','名字、存档组或队伍席位已被使用，请刷新后重试。');
 when invalid_text_representation or numeric_value_out_of_range then return jsonb_build_object('ok',false,'reason','输入格式不正确（'||op||'/'||sqlstate||'）。');
 when raise_exception then
  if authed and op='save' then return pet_private.response(a.id)||jsonb_build_object('ok',false,'conflict',true,'reason',sqlerrm); end if;
  return jsonb_build_object('ok',false,'reason',sqlerrm);
 end;
end $$;
revoke all on all functions in schema pet_private from public, anon, authenticated;
revoke all on function public.jsonb_object_length_safe(jsonb) from public, anon, authenticated;
revoke all on function public.pet_online(jsonb) from public;
grant execute on function public.pet_online(jsonb) to anon, authenticated;
notify pgrst, 'reload schema';

-- Upgrade existing level-nine pets without resetting progress or active expeditions.
update pet_private.accounts set payload=pet_private.collect_pets(pet_private.normalize_numbers(payload)),revision=revision+1
where payload is distinct from pet_private.collect_pets(pet_private.normalize_numbers(payload));

insert into pet_private.config(id,data) values(true, '{"game": {"version": 2, "title": "PetTown", "subtitle": "宠物小镇", "trainer_name": "饲主", "starting_coins": 0, "starting_diamond": 0, "rename_cost": 100, "trainer_exp_rate": 10, "starter_species": ["cat", "dog", "rabbit", "hamster"], "level_exp": [0, 50, 120, 220, 350, 520, 730, 980, 1280, 1630], "species": {"cat": {"name": "猫", "default_name": "小橘", "shop_level": 2, "price": 300, "description": "灵巧亲人的普通宠物", "base": {"hp": 100, "hunger": 100, "mood": 110, "clean": 95}, "initial_skills": {}, "forms": {"温顺": ["布偶猫", "英短"], "冒险": ["奶牛猫", "缅因猫"], "好运": ["波斯猫", "小煤球"]}, "color": "#E8A87C"}, "dog": {"name": "狗", "default_name": "豆豆", "shop_level": 2, "price": 320, "description": "精力旺盛，适合新手", "base": {"hp": 110, "hunger": 95, "mood": 105, "clean": 90}, "initial_skills": {}, "forms": {"温顺": ["萨摩耶", "柯基"], "冒险": ["哈士奇", "杜宾"], "好运": ["拉布拉多", "藏獒"]}, "color": "#C9A06A"}, "rabbit": {"name": "兔", "default_name": "雪球", "shop_level": 2, "price": 350, "description": "乖巧但容易饿", "base": {"hp": 90, "hunger": 110, "mood": 100, "clean": 105}, "initial_skills": {}, "forms": {"温顺": ["垂耳兔", "安哥拉兔"], "冒险": ["长耳兔", "花明兔"], "好运": ["玉兔", "雪兔"]}, "color": "#E6D7D0"}, "hamster": {"name": "仓鼠", "default_name": "团子", "shop_level": 2, "price": 250, "description": "小小一只，非常活泼", "base": {"hp": 80, "hunger": 90, "mood": 120, "clean": 100}, "initial_skills": {}, "forms": {"温顺": ["布丁仓鼠", "奶茶仓鼠"], "冒险": ["银狐仓鼠", "白熊仓鼠"], "好运": ["紫仓仓鼠", "金丝熊"]}, "color": "#D9B382"}, "pig": {"name": "猪", "default_name": "团子", "shop_level": 3, "price": 520, "description": "能吃能睡，但不太爱干净", "base": {"hp": 130, "hunger": 100, "mood": 120, "clean": 70}, "initial_skills": {"生存": 1}, "forms": {"温顺": ["茶杯猪"], "冒险": ["野猪"], "好运": ["香猪"]}, "color": "#E8B4B8"}, "bird": {"name": "小鸟", "default_name": "啾啾", "shop_level": 3, "price": 600, "description": "活泼聪明，喜欢互动", "base": {"hp": 110, "hunger": 120, "mood": 130, "clean": 100}, "initial_skills": {"技艺": 1}, "forms": {"温顺": ["鹦鹉", "小肥啾"], "冒险": ["猫头鹰", "游隼"], "好运": ["孔雀", "金丝雀"]}, "color": "#8FC1E3"}, "fox": {"name": "狐狸", "default_name": "阿狐", "shop_level": 4, "price": 900, "description": "聪明狡猾，有点难照顾", "base": {"hp": 150, "hunger": 120, "mood": 110, "clean": 100}, "initial_skills": {"感知": 2}, "forms": {"温顺": ["耳廓狐", "沙狐"], "冒险": ["藏狐", "赤狐"], "好运": ["九尾狐"]}, "color": "#D98E5A"}, "wolf": {"name": "狼", "default_name": "灰灰", "shop_level": 4, "price": 1000, "description": "高傲凶猛，需要更高等级", "base": {"hp": 160, "hunger": 100, "mood": 100, "clean": 120}, "initial_skills": {"探索": 2}, "forms": {"温顺": ["红狼"], "冒险": ["灰狼"], "好运": ["白狼"]}, "color": "#8A8F98"}, "leopard": {"name": "豹", "default_name": "斑点", "shop_level": 5, "price": 1500, "description": "稀有而优雅的大型生物", "base": {"hp": 200, "hunger": 190, "mood": 150, "clean": 120}, "initial_skills": {"探索": 2, "生存": 1}, "forms": {"温顺": ["雪豹"], "冒险": ["黑豹"], "好运": ["金钱豹"]}, "color": "#D9A441"}, "phoenix": {"name": "凤凰", "default_name": "小焰", "shop_level": 5, "price": 1800, "description": "传说中的神鸟", "base": {"hp": 210, "hunger": 200, "mood": 190, "clean": 200}, "initial_skills": {"感知": 2, "亲和": 1}, "forms": {"温顺": ["朱雀"], "冒险": ["黑凤"], "好运": ["不死鸟"]}, "color": "#E05A4E"}, "dragon": {"name": "龙", "default_name": "苍岚", "shop_level": 8, "price": 3000, "description": "顶级传说宠物", "base": {"hp": 300, "hunger": 240, "mood": 260, "clean": 280}, "initial_skills": {"探索": 1, "生存": 1, "感知": 1, "亲和": 1}, "forms": {"温顺": ["青龙"], "冒险": ["霸王龙"], "好运": ["翼龙"]}, "color": "#6B8E7A"}}, "work_places": {"便利店": {"seconds": 10800, "coin_min": 70, "coin_max": 130, "exp": 18, "trainer_exp": 2, "cost": {"hp": 15, "hunger": 10, "mood": 5, "clean": 5}, "required_skills": {}, "tendency": {"温顺": 1}, "skill_rolls": [{"skills": ["亲和", "技艺"], "min": 1, "max": 2, "chance": 0.75}], "desc": "站柜台、摆货，最稳定的入门打工。"}, "花店": {"seconds": 10800, "coin_min": 68, "coin_max": 128, "exp": 18, "trainer_exp": 2, "cost": {"hp": 20, "hunger": 15, "mood": 8, "clean": 8}, "required_skills": {}, "tendency": {"好运": 1}, "skill_rolls": [{"skills": ["亲和", "感知", "技艺"], "min": 1, "max": 2, "chance": 0.8}], "desc": "整理花束、招呼客人，适合亲和的宠物。"}, "工地": {"seconds": 14400, "coin_min": 120, "coin_max": 220, "exp": 26, "trainer_exp": 2, "cost": {"hp": 35, "hunger": 25, "mood": 15, "clean": 20}, "required_skills": {"any_of": [{"skill": "生存", "level": 1}, {"skill": "技艺", "level": 1}]}, "tendency": {"冒险": 2}, "skill_rolls": [{"skills": ["生存", "技艺"], "min": 1, "max": 3, "chance": 0.85}], "desc": "搬砖、扛货，体力消耗大，工资也更高。"}, "果园": {"seconds": 14400, "coin_min": 125, "coin_max": 225, "exp": 26, "trainer_exp": 2, "cost": {"hp": 30, "hunger": 30, "mood": 12, "clean": 16}, "required_skills": {"any_of": [{"skill": "探索", "level": 1}, {"skill": "感知", "level": 1}]}, "tendency": {"温顺": 2}, "skill_rolls": [{"skills": ["探索", "感知", "生存"], "min": 1, "max": 3, "chance": 0.85}], "desc": "采摘、看园子，需要一点探索或感知。"}, "酒吧": {"seconds": 28800, "coin_min": 220, "coin_max": 360, "exp": 40, "trainer_exp": 2, "cost": {"hp": 40, "hunger": 30, "mood": 12, "clean": 10}, "required_skills": {"亲和": 2}, "tendency": {"温顺": 1, "好运": 1}, "skill_rolls": [{"skills": ["亲和", "感知"], "min": 2, "max": 3, "chance": 0.85}], "desc": "招呼客人、调饮品，需要亲和 Lv.2。"}, "货轮": {"seconds": 50400, "coin_min": 300, "coin_max": 500, "exp": 65, "trainer_exp": 2, "cost": {"hp": 60, "hunger": 45, "mood": 30, "clean": 35}, "required_skills": {"探索": 2, "生存": 2}, "tendency": {"冒险": 2, "好运": 2}, "skill_rolls": [{"skills": ["探索", "生存", "感知"], "min": 2, "max": 4, "chance": 0.9}], "desc": "远洋货轮上的重活，工资最高，消耗也最大。"}}, "item_shop": {"1": {"能量糖": {"price": 10, "attr": "hp", "value": 20, "desc": "体力 +20"}, "宠物罐头": {"price": 25, "attr": "hunger", "value": 15, "desc": "饱食 +15"}, "香皂": {"price": 40, "attr": "clean", "value": 20, "desc": "清洁 +20"}}, "2": {"小饼干": {"price": 45, "attr": "hunger", "value": 30, "desc": "饱食 +30"}, "洗澡券": {"price": 80, "attr": "clean", "value": 40, "desc": "清洁 +40"}}, "3": {"豪华便当": {"price": 65, "attr": "hunger", "value": 60, "desc": "饱食 +60"}, "按摩垫": {"price": 40, "attr": "hp", "value": 80, "desc": "体力 +80"}, "逗猫棒": {"price": 60, "attr": "mood", "value": 45, "desc": "心情 +45"}, "经验条": {"price": 100, "attr": "exp", "value": 50, "desc": "经验 +50"}}, "4": {"宠物香波": {"price": 150, "attr": "clean", "value": 80, "desc": "清洁 +80"}, "快乐药剂": {"price": 120, "attr": "mood", "value": 100, "desc": "心情 +100"}}, "5": {"经验手册": {"price": 200, "attr": "exp", "value": 100, "desc": "经验 +100"}}}, "materials": {"藤种": {"tendency": "温顺", "source": ["迷雾森林"]}, "海盐": {"tendency": "温顺", "source": ["旧港仓库", "月影湾"]}, "药草": {"tendency": "温顺", "source": ["山间药园"]}, "羽绒": {"tendency": "温顺", "source": ["风栖崖"]}, "兽印": {"tendency": "冒险", "source": ["迷雾森林", "废弃矿洞", "风栖崖"]}, "锈环": {"tendency": "冒险", "source": ["旧港仓库", "古代遗迹"]}, "矿屑": {"tendency": "冒险", "source": ["废弃矿洞"]}, "矿心": {"tendency": "冒险", "source": ["废弃矿洞", "古代遗迹"]}, "月露": {"tendency": "好运", "source": ["迷雾森林", "风栖崖"]}, "旧币": {"tendency": "好运", "source": ["旧港仓库", "古代遗迹"]}, "晨露": {"tendency": "好运", "source": ["山间药园", "月影湾"]}, "灵根": {"tendency": "好运", "source": ["山间药园", "月影湾"]}}, "actions": {"work": {"label": "便利店打工", "button": "打工\n20 秒", "seconds": 20, "trainer_exp": 2, "cost": {"hp": 12, "hunger": 8, "mood": 4, "clean": 4}, "reward": {"coins_min": 18, "coins_max": 28, "exp": 8, "bond": 1}, "letter": "今天在{place}认真忙了一阵，店长夸我做事很认真。\n带回了 {coins} 金币。"}, "rest": {"label": "回家休息", "button": "休息\n4 小时", "seconds": 14400, "trainer_exp": 2, "cost": {}, "reward": {"coins_min": 0, "coins_max": 0, "exp": 2, "bond": 1, "hp": 30}, "letter": "睡了一觉，梦见自己会飞。\n体力恢复了 {hp} 点。"}, "play": {"label": "一起玩耍", "button": "玩耍\n8 秒", "seconds": 8, "trainer_exp": 2, "cost": {"hp": 5, "clean": 3}, "reward": {"coins_min": 0, "coins_max": 0, "exp": 5, "bond": 2, "mood": 15}, "letter": "你陪我玩了一会儿，我把球藏到了沙发底下。\n心情 +{mood}，羁绊 +{bond}。"}, "feed": {"label": "喂食清洁", "button": "照顾\n5 秒", "seconds": 5, "trainer_exp": 1, "coin_cost": 6, "cost": {}, "reward": {"coins_min": 0, "coins_max": 0, "exp": 1, "bond": 1, "hunger": 30, "clean": 25, "mood": 5}, "letter": "我吃了一大碗，还洗了个香香的澡。\n饱食 +{hunger}，清洁 +{clean}。"}}, "tendency_rules": {"rest_start": {"温顺": 4}, "work_start": {"冒险": 1}, "play": {"温顺": 1, "冒险": 1}, "play_together": {"温顺": 1}, "battle": {"冒险": 1}, "battle_defender_win": {"好运": 2}, "use_item": {"温顺": 1, "好运": 1}, "skill_exp_success": {"好运": 2}, "work_high_coin": {"好运": 2}, "play_high_mood": {"好运": 1}}, "skill_rules": {"max_level": 3, "need_exp": [5, 12, 25, 45, 75], "rest_finish": {"rolls": [{"skills": ["生存", "感知"], "min": 1, "max": 2, "chance": 0.7}]}, "play": {"rolls": [{"skills": ["探索", "亲和"], "min": 1, "max": 2, "chance": 0.75}]}}}, "expeditions": {"迷雾森林": {"seconds": 10800, "required_skills": {"探索": 2, "生存": 1, "感知": 1}, "exp": 35, "cost": {"hp": 35, "hunger": 25, "mood": 32, "clean": 18}, "tendency": {"冒险": 2}, "skill_exp": {"rolls": [{"skills": ["探索", "生存", "感知"], "min": 1, "max": 3, "chance": 0.85}]}, "fixed_rewards": {"coin": 100, "藤种": 1}, "random_rewards": [{"item": "月露", "count": 1, "weight": 35}, {"item": "兽印", "count": 1, "weight": 15}, {"item": "空", "count": 0, "weight": 20}]}, "旧港仓库": {"seconds": 10800, "required_skills": {"探索": 1, "技艺": 2, "感知": 1}, "exp": 35, "cost": {"hp": 35, "hunger": 25, "mood": 32, "clean": 18}, "tendency": {"冒险": 1, "好运": 1}, "skill_exp": {"rolls": [{"skills": ["探索", "技艺", "感知"], "min": 1, "max": 3, "chance": 0.85}]}, "fixed_rewards": {"coin": 120, "旧币": 1}, "random_rewards": [{"item": "海盐", "count": 1, "weight": 35}, {"item": "锈环", "count": 1, "weight": 20}, {"item": "空", "count": 0, "weight": 15}]}, "山间药园": {"seconds": 10800, "required_skills": {"生存": 2, "感知": 2}, "exp": 35, "cost": {"hp": 30, "hunger": 22, "mood": 30, "clean": 16}, "tendency": {"温顺": 1, "好运": 1}, "skill_exp": {"rolls": [{"skills": ["生存", "感知"], "min": 1, "max": 3, "chance": 0.85}]}, "fixed_rewards": {"coin": 100, "药草": 1}, "random_rewards": [{"item": "晨露", "count": 1, "weight": 35}, {"item": "灵根", "count": 1, "weight": 15}, {"item": "空", "count": 0, "weight": 20}]}, "废弃矿洞": {"seconds": 10800, "required_skills": {"生存": 2, "技艺": 1, "探索": 1}, "exp": 45, "cost": {"hp": 45, "hunger": 35, "mood": 38, "clean": 25}, "tendency": {"冒险": 3}, "skill_exp": {"rolls": [{"skills": ["生存", "技艺", "探索"], "min": 2, "max": 4, "chance": 0.9}]}, "fixed_rewards": {"coin": 140, "矿屑": 1}, "random_rewards": [{"item": "矿心", "count": 1, "weight": 18}, {"item": "兽印", "count": 1, "weight": 12}, {"item": "空", "count": 0, "weight": 25}]}, "风栖崖": {"seconds": 14400, "required_skills": {"探索": 2, "亲和": 1, "感知": 2}, "exp": 45, "cost": {"hp": 42, "hunger": 30, "mood": 36, "clean": 22}, "tendency": {"温顺": 1, "冒险": 2}, "skill_exp": {"rolls": [{"skills": ["探索", "亲和", "感知"], "min": 2, "max": 4, "chance": 0.9}]}, "fixed_rewards": {"coin": 135, "羽绒": 1}, "random_rewards": [{"item": "月露", "count": 1, "weight": 25}, {"item": "兽印", "count": 1, "weight": 20}, {"item": "空", "count": 0, "weight": 20}]}, "月影湖": {"seconds": 14400, "required_skills": {"生存": 1, "感知": 3, "亲和": 1}, "exp": 45, "cost": {"hp": 36, "hunger": 28, "mood": 34, "clean": 20}, "tendency": {"温顺": 2, "好运": 1}, "skill_exp": {"rolls": [{"skills": ["生存", "感知", "亲和"], "min": 2, "max": 4, "chance": 0.9}]}, "fixed_rewards": {"coin": 130, "海盐": 1}, "random_rewards": [{"item": "晨露", "count": 1, "weight": 25}, {"item": "灵根", "count": 1, "weight": 18}, {"item": "空", "count": 0, "weight": 20}]}, "古代遗迹": {"seconds": 18000, "required_skills": {"探索": 3, "技艺": 2, "感知": 2}, "exp": 55, "cost": {"hp": 50, "hunger": 42, "mood": 42, "clean": 36}, "tendency": {"冒险": 2, "好运": 2}, "skill_exp": {"rolls": [{"skills": ["探索", "技艺", "感知"], "min": 3, "max": 5, "chance": 0.92}]}, "fixed_rewards": {"coin": 180, "锈环": 1}, "random_rewards": [{"item": "矿心", "count": 1, "weight": 18}, {"item": "旧币", "count": 1, "weight": 25}, {"item": "空", "count": 0, "weight": 20}]}}}'::jsonb) on conflict(id) do update set data=excluded.data;

commit;
