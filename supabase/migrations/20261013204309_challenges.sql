-- Async challenges: two players solve the same secret. The server keeps the answer and scores every guess
-- (supabase/functions/create-challenge and challenge-guess); everything else goes through the functions below.

create table public.challenges (
  id uuid primary key default gen_random_uuid(),
  creator uuid not null references public.profiles (id) on delete cascade,
  opponent uuid references public.profiles (id) on delete cascade,  -- null until someone claims a link challenge
  link_code text unique,                                              -- set for "anyone with the link" challenges
  parts text[] not null check (cardinality(parts) between 1 and 8),
  max_guesses int check (max_guesses is null or max_guesses between 1 and 50),
  status text not null default 'pending' check (status in ('pending', 'active', 'finished', 'declined', 'expired', 'cancelled')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  expires_at timestamptz not null default now() + interval '24 hours',  -- to accept; accepting gives both players 24 hours more
  finished_at timestamptz,
  winner uuid references public.profiles (id) on delete set null,   -- stays null for a draw
  rematch_of uuid references public.challenges (id) on delete set null,
  check (opponent is null or opponent <> creator),
  check (link_code is not null or opponent is not null)
);
create index challenges_creator_idx on public.challenges (creator, created_at desc);
create index challenges_opponent_idx on public.challenges (opponent, created_at desc);

-- The answer and the clue. No player can read this table; only the server functions can.
create table public.challenge_secrets (
  challenge_id uuid primary key references public.challenges (id) on delete cascade,
  char_id text not null,
  hint text not null
);

create table public.challenge_players (
  challenge_id uuid not null references public.challenges (id) on delete cascade,
  player uuid not null references public.profiles (id) on delete cascade,
  started_at timestamptz,
  finished_at timestamptz,
  solved boolean not null default false,
  gave_up boolean not null default false,
  guess_count int not null default 0,
  primary key (challenge_id, player)
);
create index challenge_players_player_idx on public.challenge_players (player);

create table public.challenge_guesses (
  challenge_id uuid not null,
  player uuid not null,
  n int not null check (n >= 1),
  char_id text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (challenge_id, player, n),
  unique (challenge_id, player, char_id),
  foreign key (challenge_id, player) references public.challenge_players (challenge_id, player) on delete cascade
);

alter table public.challenges enable row level security;
alter table public.challenge_secrets enable row level security;
alter table public.challenge_players enable row level security;
alter table public.challenge_guesses enable row level security;

-- Players get no direct access: the functions decide what each one may see (e.g. the answer only once they finish).
grant select, insert, update, delete on table public.challenges, public.challenge_secrets,
  public.challenge_players, public.challenge_guesses to service_role;

-- More error codes the site turns into messages:
--   JJ006 no such challenge, JJ007 the challenge is over, JJ008 you already finished, JJ009 not friends,
--   JJ010 too many open challenges, JJ011 challenge unavailable, JJ012 your own challenge, JJ013 already guessed

-- Is either player blocking the other? Internal only: players can't use it to discover blocks.
create function public.blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a));
$$;

-- Settle a challenge once both players are done, or when it runs out of time. Safe to call any time.
-- Fewest guesses wins, a faster solve breaks a tie; nobody solving it (or an exact tie) is a draw.
create function public.finalize_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.challenges;
  a public.challenge_players;
  b public.challenge_players;
  ta interval;
  tb interval;
  w uuid;
begin
  select * into c from public.challenges where id = p_id for update;
  if not found or c.status not in ('pending', 'active') then return; end if;

  if c.status = 'pending' then
    if now() >= c.expires_at then
      update public.challenges set status = 'expired', finished_at = now() where id = p_id;
    end if;
    return;
  end if;

  select * into a from public.challenge_players where challenge_id = p_id and player = c.creator for update;
  select * into b from public.challenge_players where challenge_id = p_id and player = c.opponent for update;
  if (a.finished_at is null or b.finished_at is null) and now() < c.expires_at then return; end if;

  -- out of time: anyone still playing didn't solve it
  update public.challenge_players set finished_at = c.expires_at where challenge_id = p_id and finished_at is null;
  select * into a from public.challenge_players where challenge_id = p_id and player = c.creator;
  select * into b from public.challenge_players where challenge_id = p_id and player = c.opponent;

  if a.solved and not b.solved then w := a.player;
  elsif b.solved and not a.solved then w := b.player;
  elsif a.solved and b.solved then
    if a.guess_count <> b.guess_count then
      w := case when a.guess_count < b.guess_count then a.player else b.player end;
    else
      ta := a.finished_at - coalesce(a.started_at, a.finished_at);
      tb := b.finished_at - coalesce(b.started_at, b.finished_at);
      w := case when ta < tb then a.player when tb < ta then b.player end;
    end if;
  end if;
  update public.challenges set status = 'finished', finished_at = now(), winner = w where id = p_id;
end;
$$;

-- ---------- for the server functions only (they hold the answer-picking and scoring code) ----------

create function public.sv_create_challenge(
  p_creator uuid, p_opponent uuid, p_link_code text, p_parts text[], p_max_guesses int,
  p_char_id text, p_hint text, p_rematch_of uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
  prev public.challenges;
begin
  if not exists (select 1 from public.profiles where id = p_creator) then
    raise exception 'pick a username first' using errcode = 'JJ001';
  end if;

  if p_rematch_of is not null then
    -- the lock makes a second rematch request wait, then find the first one's challenge
    select * into prev from public.challenges where id = p_rematch_of for update;
    if not found or p_creator not in (prev.creator, prev.opponent) or prev.status <> 'finished' or prev.opponent is null then
      raise exception 'no such challenge' using errcode = 'JJ006';
    end if;
    -- either player asking again gets the rematch that's already open
    select id into new_id from public.challenges
      where rematch_of = p_rematch_of and status in ('pending', 'active') and expires_at > now()
      order by created_at desc limit 1;
    if new_id is not null then return new_id; end if;
    p_opponent := case when prev.creator = p_creator then prev.opponent else prev.creator end;
    p_link_code := null;
  end if;

  if (select count(*) from public.challenges
      where creator = p_creator and status in ('pending', 'active') and expires_at > now()) >= 20 then
    raise exception 'too many open challenges' using errcode = 'JJ010';
  end if;

  if p_opponent is not null then
    if p_opponent = p_creator then raise exception 'that is you' using errcode = 'JJ003'; end if;
    if public.blocked_between(p_creator, p_opponent) then raise exception 'challenge unavailable' using errcode = 'JJ011'; end if;
    -- direct challenges go to friends; a rematch works with anyone you've just played
    if p_rematch_of is null and not exists (
        select 1 from public.friendships
        where user_low = least(p_creator, p_opponent) and user_high = greatest(p_creator, p_opponent) and status = 'accepted') then
      raise exception 'not friends' using errcode = 'JJ009';
    end if;
  elsif p_link_code is null then
    raise exception 'a challenge needs an opponent or a link' using errcode = 'JJ006';
  end if;

  insert into public.challenges (creator, opponent, link_code, parts, max_guesses, rematch_of)
    values (p_creator, p_opponent, p_link_code, p_parts, p_max_guesses, p_rematch_of)
    returning id into new_id;
  insert into public.challenge_secrets (challenge_id, char_id, hint) values (new_id, p_char_id, p_hint);
  insert into public.challenge_players (challenge_id, player) values (new_id, p_creator);
  return new_id;
end;
$$;

-- What the scoring function needs: the answer, the rules, and what this player has guessed so far.
create function public.sv_guess_context(p_id uuid, p_player uuid)
returns table (status text, parts text[], max_guesses int, char_id text, hint text, finished boolean, guess_count int, guessed text[])
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.finalize_challenge(p_id);
  return query
    select c.status, c.parts, c.max_guesses, s.char_id, s.hint, p.finished_at is not null, p.guess_count,
           coalesce((select array_agg(g.char_id) from public.challenge_guesses g
                     where g.challenge_id = p_id and g.player = p_player), '{}'::text[])
    from public.challenges c
    join public.challenge_secrets s on s.challenge_id = c.id
    join public.challenge_players p on p.challenge_id = c.id and p.player = p_player
    where c.id = p_id;
end;
$$;

-- Record a scored guess. Locks the player's row so double-clicks can't skip or repeat a guess.
create function public.sv_record_guess(p_id uuid, p_player uuid, p_char_id text, p_result jsonb, p_correct boolean)
returns table (n int, finished boolean, solved boolean, status text, winner uuid)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  c public.challenges;
  me public.challenge_players;
  next_n int;
begin
  select * into c from public.challenges where id = p_id for update;
  if not found then raise exception 'no such challenge' using errcode = 'JJ006'; end if;
  if c.status not in ('pending', 'active') or now() >= c.expires_at then
    raise exception 'the challenge is over' using errcode = 'JJ007';
  end if;
  select * into me from public.challenge_players where challenge_id = p_id and player = p_player for update;
  if not found then raise exception 'no such challenge' using errcode = 'JJ006'; end if;
  if me.finished_at is not null then raise exception 'you already finished' using errcode = 'JJ008'; end if;
  if exists (select 1 from public.challenge_guesses g where g.challenge_id = p_id and g.player = p_player and g.char_id = p_char_id) then
    raise exception 'already guessed' using errcode = 'JJ013';
  end if;

  next_n := me.guess_count + 1;
  insert into public.challenge_guesses (challenge_id, player, n, char_id, result)
    values (p_id, p_player, next_n, p_char_id, p_result);
  update public.challenge_players set
      guess_count = next_n,
      started_at = coalesce(me.started_at, now()),
      solved = p_correct,
      finished_at = case when p_correct or (c.max_guesses is not null and next_n >= c.max_guesses) then now() end
    where challenge_id = p_id and player = p_player;
  perform public.finalize_challenge(p_id);

  return query
    select p.guess_count, p.finished_at is not null, p.solved, ch.status, ch.winner
    from public.challenge_players p
    join public.challenges ch on ch.id = p.challenge_id
    where p.challenge_id = p_id and p.player = p_player;
end;
$$;

-- ---------- for players ----------

-- What a challenge link shows before you accept it (never the answer).
create function public.peek_challenge(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  c public.challenges;
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  perform public.finalize_challenge((select id from public.challenges where link_code = p_code));
  select * into c from public.challenges where link_code = p_code;
  if not found or public.blocked_between(c.creator, me) then
    raise exception 'challenge unavailable' using errcode = 'JJ011';
  end if;
  return jsonb_build_object(
    'id', c.id,
    'creator', (select username from public.profiles where id = c.creator),
    'mine', c.creator = me,
    'claimed', c.opponent is not null,
    'claimed_by_me', coalesce(c.opponent = me, false),
    'status', c.status,
    'parts', c.parts,
    'max_guesses', c.max_guesses,
    'expires_at', c.expires_at);
end;
$$;

-- Accept a challenge sent to you, or claim a link challenge by its code.
create function public.accept_challenge(p_id uuid default null, p_code text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  c public.challenges;
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = me) then
    raise exception 'pick a username first' using errcode = 'JJ001';
  end if;
  if p_code is not null then
    select * into c from public.challenges where link_code = p_code;
  else
    select * into c from public.challenges where id = p_id;
  end if;
  if not found then raise exception 'challenge unavailable' using errcode = 'JJ011'; end if;
  perform public.finalize_challenge(c.id);
  select * into c from public.challenges where id = c.id for update;

  if c.creator = me then raise exception 'that is your own challenge' using errcode = 'JJ012'; end if;
  if c.opponent = me and c.status = 'active' then return c.id; end if;  -- already accepted
  if c.status <> 'pending'
     or (c.opponent is not null and c.opponent <> me)
     or (c.opponent is null and p_code is null)   -- links are claimed with their code
     or public.blocked_between(c.creator, me) then
    raise exception 'challenge unavailable' using errcode = 'JJ011';
  end if;

  update public.challenges set opponent = me, status = 'active', accepted_at = now(), expires_at = now() + interval '24 hours'
    where id = c.id;
  insert into public.challenge_players (challenge_id, player) values (c.id, me) on conflict do nothing;
  return c.id;
end;
$$;

create function public.decline_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  update public.challenges set status = 'declined', finished_at = now()
    where id = p_id and opponent = auth.uid() and status = 'pending';
  if not found then raise exception 'challenge unavailable' using errcode = 'JJ011'; end if;
end;
$$;

-- Take back a challenge nobody has accepted yet.
create function public.cancel_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  update public.challenges set status = 'cancelled', finished_at = now()
    where id = p_id and creator = auth.uid() and status = 'pending';
  if not found then raise exception 'challenge unavailable' using errcode = 'JJ011'; end if;
end;
$$;

-- Your clock starts when you first open a challenge.
create function public.start_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  update public.challenge_players p set started_at = now()
    from public.challenges c
    where p.challenge_id = p_id and p.player = auth.uid() and p.started_at is null
      and c.id = p.challenge_id and c.status in ('pending', 'active') and now() < c.expires_at;
end;
$$;

create function public.give_up_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  perform public.finalize_challenge(p_id);
  update public.challenge_players p set finished_at = now(), gave_up = true, started_at = coalesce(p.started_at, now())
    from public.challenges c
    where p.challenge_id = p_id and p.player = auth.uid() and p.finished_at is null
      and c.id = p.challenge_id and c.status in ('pending', 'active') and now() < c.expires_at;
  if not found then raise exception 'the challenge is over' using errcode = 'JJ007'; end if;
  perform public.finalize_challenge(p_id);
end;
$$;

-- One challenge from your side: your guesses, and your opponent's only once you can see them.
create function public.get_challenge(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  c public.challenges;
  mine public.challenge_players;
  theirs public.challenge_players;
  other uuid;
  reveal boolean;
  s public.challenge_secrets;
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  perform public.finalize_challenge(p_id);
  select * into c from public.challenges where id = p_id and me in (creator, opponent);
  if not found then raise exception 'no such challenge' using errcode = 'JJ006'; end if;
  other := case when c.creator = me then c.opponent else c.creator end;
  select * into mine from public.challenge_players where challenge_id = p_id and player = me;
  select * into theirs from public.challenge_players where challenge_id = p_id and player = other;
  select * into s from public.challenge_secrets where challenge_id = p_id;
  reveal := c.status in ('finished', 'expired', 'declined', 'cancelled') or mine.finished_at is not null;

  return jsonb_build_object(
    'id', c.id,
    'status', c.status,
    'role', case when c.creator = me then 'creator' else 'opponent' end,
    'opponent', (select jsonb_build_object('id', p.id, 'username', p.username) from public.profiles p where p.id = other),
    'link_code', case when c.creator = me then c.link_code end,
    'parts', c.parts,
    'max_guesses', c.max_guesses,
    'created_at', c.created_at,
    'expires_at', c.expires_at,
    'finished_at', c.finished_at,
    'me', jsonb_build_object(
      'started_at', mine.started_at, 'finished_at', mine.finished_at,
      'solved', coalesce(mine.solved, false), 'gave_up', coalesce(mine.gave_up, false),
      'guess_count', coalesce(mine.guess_count, 0),
      'time_ms', case when mine.solved then (extract(epoch from (mine.finished_at - mine.started_at)) * 1000)::bigint end,
      'guesses', coalesce((select jsonb_agg(jsonb_build_object('n', g.n, 'char_id', g.char_id, 'result', g.result) order by g.n)
                           from public.challenge_guesses g where g.challenge_id = p_id and g.player = me), '[]'::jsonb)),
    'them', case
      when theirs.player is null then null
      when c.status = 'finished' then jsonb_build_object(
        'finished', true, 'solved', theirs.solved, 'gave_up', theirs.gave_up, 'guess_count', theirs.guess_count,
        'time_ms', case when theirs.solved then (extract(epoch from (theirs.finished_at - theirs.started_at)) * 1000)::bigint end,
        'guesses', coalesce((select jsonb_agg(jsonb_build_object('n', g.n, 'char_id', g.char_id, 'result', g.result) order by g.n)
                             from public.challenge_guesses g where g.challenge_id = p_id and g.player = other), '[]'::jsonb))
      else jsonb_build_object('finished', theirs.finished_at is not null) end,
    'secret', case when reveal then s.char_id end,
    'hint', case when coalesce(mine.guess_count, 0) >= 8 or reveal then s.hint end,
    'result', case when c.status = 'finished' then
      case when c.winner is null then 'draw' when c.winner = me then 'win' else 'loss' end end
  );
end;
$$;

-- Your inbox: open challenges plus anything finished in the last week (newest first).
create function public.list_challenges()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  r record;
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  for r in select id from public.challenges
           where me in (creator, opponent) and status in ('pending', 'active') and expires_at <= now() loop
    perform public.finalize_challenge(r.id);
  end loop;
  return coalesce((
    select jsonb_agg(x order by created desc)
    from (
      select c.created_at as created, jsonb_build_object(
        'id', c.id,
        'status', c.status,
        'role', case when c.creator = me then 'creator' else 'opponent' end,
        'opponent', (select p.username from public.profiles p where p.id = case when c.creator = me then c.opponent else c.creator end),
        'link_code', case when c.creator = me then c.link_code end,
        'parts', c.parts,
        'max_guesses', c.max_guesses,
        'created_at', c.created_at,
        'expires_at', c.expires_at,
        'my_started', mp.started_at is not null,
        'my_finished', mp.finished_at is not null,
        'their_finished', tp.finished_at is not null,
        'result', case when c.status = 'finished' then
          case when c.winner is null then 'draw' when c.winner = me then 'win' else 'loss' end end,
        'my_guesses', case when c.status = 'finished' then mp.guess_count end,
        'their_guesses', case when c.status = 'finished' then tp.guess_count end) as x
      from public.challenges c
      left join public.challenge_players mp on mp.challenge_id = c.id and mp.player = me
      left join public.challenge_players tp on tp.challenge_id = c.id
        and tp.player = case when c.creator = me then c.opponent else c.creator end
      where me in (c.creator, c.opponent)
        and (c.status in ('pending', 'active') or c.finished_at > now() - interval '7 days')
      order by c.created_at desc
      limit 50
    ) t), '[]'::jsonb);
end;
$$;

-- Blocking also takes back any challenges between the two players that haven't been accepted.
create or replace function public.block_player(other uuid)
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
  update public.challenges set status = 'cancelled', finished_at = now()
    where status = 'pending' and ((creator = me and opponent = other) or (creator = other and opponent = me));
end;
$$;

-- ---------- live updates ----------
-- Each player listens on a private channel "user:<id>". The database pings it when something changes;
-- the page then reloads the list (the ping itself carries no details).
create policy "players hear their own updates" on realtime.messages
  for select to authenticated
  using ((select realtime.topic()) = 'user:' || (select auth.uid())::text);

create function public.notify_players(kind text, a uuid, b uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if a is not null then
    perform realtime.send(jsonb_build_object('kind', kind), 'changed', 'user:' || a::text, true);
  end if;
  if b is not null and b is distinct from a then
    perform realtime.send(jsonb_build_object('kind', kind), 'changed', 'user:' || b::text, true);
  end if;
end;
$$;

create function public.on_friendship_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform public.notify_players('friends', old.user_low, old.user_high);
  else
    perform public.notify_players('friends', new.user_low, new.user_high);
  end if;
  return null;
end;
$$;
create trigger friendships_notify after insert or update or delete on public.friendships
  for each row execute function public.on_friendship_change();

create function public.on_challenge_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.notify_players('challenges', new.creator, new.opponent);
  return null;
end;
$$;
create trigger challenges_notify after insert or update on public.challenges
  for each row execute function public.on_challenge_change();

-- A player finishing is news for both (individual guesses stay private until the end).
create function public.on_challenge_player_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.challenges;
begin
  if new.finished_at is not null and old.finished_at is null then
    select * into c from public.challenges where id = new.challenge_id;
    perform public.notify_players('challenges', c.creator, c.opponent);
  end if;
  return null;
end;
$$;
create trigger challenge_players_notify after update on public.challenge_players
  for each row execute function public.on_challenge_player_change();

-- ---------- who may call what ----------
revoke execute on function public.blocked_between(uuid, uuid), public.finalize_challenge(uuid),
  public.notify_players(text, uuid, uuid), public.on_friendship_change(), public.on_challenge_change(),
  public.on_challenge_player_change() from public, anon, authenticated;

revoke execute on function public.sv_create_challenge(uuid, uuid, text, text[], int, text, text, uuid),
  public.sv_guess_context(uuid, uuid), public.sv_record_guess(uuid, uuid, text, jsonb, boolean)
  from public, anon, authenticated;
grant execute on function public.sv_create_challenge(uuid, uuid, text, text[], int, text, text, uuid),
  public.sv_guess_context(uuid, uuid), public.sv_record_guess(uuid, uuid, text, jsonb, boolean) to service_role;

revoke execute on function public.peek_challenge(text), public.accept_challenge(uuid, text), public.decline_challenge(uuid),
  public.cancel_challenge(uuid), public.start_challenge(uuid), public.give_up_challenge(uuid), public.get_challenge(uuid),
  public.list_challenges() from public, anon;
grant execute on function public.peek_challenge(text), public.accept_challenge(uuid, text), public.decline_challenge(uuid),
  public.cancel_challenge(uuid), public.start_challenge(uuid), public.give_up_challenge(uuid), public.get_challenge(uuid),
  public.list_challenges() to authenticated;
