-- Friends: one row per pair of players (lower id first), pending until the other player accepts.
create table public.friendships (
  user_low uuid not null references public.profiles (id) on delete cascade,
  user_high uuid not null references public.profiles (id) on delete cascade,
  requested_by uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (user_low, user_high),
  check (user_low < user_high),
  check (requested_by = user_low or requested_by = user_high)
);
create index friendships_user_high_idx on public.friendships (user_high);

-- Blocks are private: only the blocker can see them.
create table public.blocks (
  blocker uuid not null references public.profiles (id) on delete cascade,
  blocked uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
create index blocks_blocked_idx on public.blocks (blocked);

alter table public.friendships enable row level security;
alter table public.blocks enable row level security;

-- Players can read their own rows; every change goes through the functions below.
grant select on table public.friendships to authenticated;
grant select on table public.blocks to authenticated;
grant select, insert, update, delete on table public.friendships to service_role;
grant select, insert, update, delete on table public.blocks to service_role;

create policy "players see their own friendships" on public.friendships
  for select to authenticated using ((select auth.uid()) in (user_low, user_high));

create policy "players see who they blocked" on public.blocks
  for select to authenticated using (blocker = (select auth.uid()));

-- Error codes the site turns into messages:
--   JJ001 pick a username first, JJ002 no such player, JJ003 that's you,
--   JJ004 you blocked this player, JJ005 that request is gone

-- Send a friend request by username. Returns 'pending' or 'accepted'.
create function public.send_friend_request(target_username text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  them uuid;
  lo uuid;
  hi uuid;
  existing public.friendships;
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = me) then
    raise exception 'pick a username first' using errcode = 'JJ001';
  end if;
  select id into them from public.profiles where lower(username) = lower(trim(target_username));
  if them is null then raise exception 'no player with that username' using errcode = 'JJ002'; end if;
  if them = me then raise exception 'that is you' using errcode = 'JJ003'; end if;
  if exists (select 1 from public.blocks where blocker = me and blocked = them) then
    raise exception 'you blocked this player' using errcode = 'JJ004';
  end if;
  -- if they blocked me, look like the request was sent without revealing the block
  if exists (select 1 from public.blocks where blocker = them and blocked = me) then return 'pending'; end if;

  lo := least(me, them);
  hi := greatest(me, them);
  select * into existing from public.friendships where user_low = lo and user_high = hi for update;
  if found then
    if existing.status = 'accepted' then return 'accepted'; end if;
    if existing.requested_by = me then return 'pending'; end if;
    -- they had already asked me, so asking back accepts
    update public.friendships set status = 'accepted', responded_at = now() where user_low = lo and user_high = hi;
    return 'accepted';
  end if;
  insert into public.friendships (user_low, user_high, requested_by) values (lo, hi, me);
  return 'pending';
end;
$$;

-- Accept or decline a request someone else sent me.
create function public.respond_friend_request(other uuid, accept boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if accept then
    update public.friendships set status = 'accepted', responded_at = now()
      where user_low = least(me, other) and user_high = greatest(me, other) and status = 'pending' and requested_by = other;
  else
    delete from public.friendships
      where user_low = least(me, other) and user_high = greatest(me, other) and status = 'pending' and requested_by = other;
  end if;
  if not found then raise exception 'that request is gone' using errcode = 'JJ005'; end if;
  return case when accept then 'accepted' else 'declined' end;
end;
$$;

-- Cancel a request I sent, or remove a friend.
create function public.remove_friend(other uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  delete from public.friendships
    where user_low = least(me, other) and user_high = greatest(me, other) and (status = 'accepted' or requested_by = me);
end;
$$;

-- Block a player: ends any friendship and quietly stops their requests.
create function public.block_player(other uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if other = me then raise exception 'that is you' using errcode = 'JJ003'; end if;
  if not exists (select 1 from public.profiles where id = other) then
    raise exception 'no such player' using errcode = 'JJ002';
  end if;
  insert into public.blocks (blocker, blocked) values (me, other) on conflict do nothing;
  delete from public.friendships where user_low = least(me, other) and user_high = greatest(me, other);
end;
$$;

create function public.unblock_player(other uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  delete from public.blocks where blocker = auth.uid() and blocked = other;
end;
$$;

-- My friends and requests with usernames: state is 'friend', 'incoming' or 'outgoing'.
create function public.list_friends()
returns table (id uuid, username text, state text, since timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  select p.id, p.username,
         case when f.status = 'accepted' then 'friend'
              when f.requested_by = (select auth.uid()) then 'outgoing'
              else 'incoming' end,
         coalesce(f.responded_at, f.created_at)
  from public.friendships f
  join public.profiles p on p.id = case when f.user_low = (select auth.uid()) then f.user_high else f.user_low end
  where (select auth.uid()) in (f.user_low, f.user_high)
  order by lower(p.username);
$$;

create function public.list_blocked()
returns table (id uuid, username text)
language sql
stable
security invoker
set search_path = ''
as $$
  select p.id, p.username
  from public.blocks b
  join public.profiles p on p.id = b.blocked
  where b.blocker = (select auth.uid())
  order by lower(p.username);
$$;

-- Only signed-in players may call these.
revoke execute on function public.send_friend_request(text), public.respond_friend_request(uuid, boolean),
  public.remove_friend(uuid), public.block_player(uuid), public.unblock_player(uuid),
  public.list_friends(), public.list_blocked() from public, anon;
grant execute on function public.send_friend_request(text), public.respond_friend_request(uuid, boolean),
  public.remove_friend(uuid), public.block_player(uuid), public.unblock_player(uuid),
  public.list_friends(), public.list_blocked() to authenticated;
