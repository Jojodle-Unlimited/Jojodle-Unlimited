-- Live races: both players play the same answer at the same moment and the first to solve wins.
-- A race is a challenge with mode 'race'. Once it's accepted, both players wait in a lobby while their pages check
-- in every few seconds (race_ready); when both are there, the race starts 4 seconds later, the same moment on both
-- boards. Guesses before the start are refused. Every guess pings the other player, whose page then shows the
-- opponent's colours as they go (never which characters they guessed).
-- More error codes: JJ014 the race hasn't started yet

alter table public.challenges
  add column mode text not null default 'async' check (mode in ('async', 'race')),
  add column starts_at timestamptz;  -- when a race starts (set once both players are in the lobby)
alter table public.challenge_players add column ready_at timestamptz;  -- last check-in from the race lobby

-- Settle a challenge once it's decided, or when it runs out of time. Safe to call any time.
-- Turns: fewest guesses wins, a faster solve breaks a tie; nobody solving it (or an exact tie) is a draw.
-- Races: the first to solve wins at once; both out without solving, or time running out, is a draw.
create or replace function public.finalize_challenge(p_id uuid)
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

  -- not accepted in time, or a race whose players never were both there
  if c.status = 'pending' or (c.mode = 'race' and c.starts_at is null) then
    if now() >= c.expires_at then
      update public.challenges set status = 'expired', finished_at = now() where id = p_id;
    end if;
    return;
  end if;

  select * into a from public.challenge_players where challenge_id = p_id and player = c.creator for update;
  select * into b from public.challenge_players where challenge_id = p_id and player = c.opponent for update;

  if c.mode = 'race' then
    if a.solved or b.solved then
      w := case when a.solved and (not b.solved or a.finished_at <= b.finished_at) then a.player else b.player end;
    elsif (a.finished_at is null or b.finished_at is null) and now() < c.expires_at then
      return;
    end if;
    -- the race is over for whoever was still playing
    update public.challenge_players set finished_at = least(now(), c.expires_at) where challenge_id = p_id and finished_at is null;
    update public.challenges set status = 'finished', finished_at = now(), winner = w where id = p_id;
    return;
  end if;

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

-- Creating takes the kind of game too. Races wait 10 minutes for the other player instead of 24 hours.
drop function public.sv_create_challenge(uuid, uuid, text, text[], int, text, text, uuid);
create function public.sv_create_challenge(
  p_creator uuid, p_opponent uuid, p_link_code text, p_parts text[], p_max_guesses int,
  p_char_id text, p_hint text, p_rematch_of uuid default null, p_mode text default 'async'
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
    p_mode := prev.mode;  -- a rematch is the same kind of game
  end if;
  if p_mode is null or p_mode not in ('async', 'race') then raise exception 'bad mode' using errcode = '22023'; end if;

  if (select count(*) from public.challenges
      where creator = p_creator and status in ('pending', 'active') and expires_at > now()) >= 20 then
    raise exception 'too many open challenges' using errcode = 'JJ010';
  end if;

  if p_opponent is not null then
    if p_opponent = p_creator then raise exception 'that is you' using errcode = 'JJ003'; end if;
    -- direct challenges go to friends; a rematch works with anyone you've just played
    if p_rematch_of is null and not exists (
        select 1 from public.friendships
        where user_low = least(p_creator, p_opponent) and user_high = greatest(p_creator, p_opponent) and status = 'accepted') then
      raise exception 'not friends' using errcode = 'JJ009';
    end if;
    if public.blocked_between(p_creator, p_opponent) then raise exception 'challenge unavailable' using errcode = 'JJ011'; end if;
  elsif p_link_code is null then
    raise exception 'a challenge needs an opponent or a link' using errcode = 'JJ006';
  end if;

  insert into public.challenges (creator, opponent, link_code, parts, max_guesses, rematch_of, mode, expires_at)
    values (p_creator, p_opponent, p_link_code, p_parts, p_max_guesses, p_rematch_of, p_mode,
            now() + case when p_mode = 'race' then interval '10 minutes' else interval '24 hours' end)
    returning id into new_id;
  insert into public.challenge_secrets (challenge_id, char_id, hint) values (new_id, p_char_id, p_hint);
  insert into public.challenge_players (challenge_id, player) values (new_id, p_creator);
  return new_id;
end;
$$;
revoke execute on function public.sv_create_challenge(uuid, uuid, text, text[], int, text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.sv_create_challenge(uuid, uuid, text, text[], int, text, text, uuid, text) to service_role;

-- Guesses in a race only count once it has started.
create or replace function public.sv_record_guess(p_id uuid, p_player uuid, p_char_id text, p_result jsonb, p_correct boolean)
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
  if c.mode = 'race' and (c.starts_at is null or now() < c.starts_at) then
    raise exception 'the race has not started' using errcode = 'JJ014';
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
      started_at = coalesce(me.started_at, c.starts_at, now()),
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

-- Accepting a race opens a 10-minute window for both players to be in the lobby.
create or replace function public.accept_challenge(p_id uuid default null, p_code text default null)
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

  update public.challenges set opponent = me, status = 'active', accepted_at = now(),
      expires_at = now() + case when c.mode = 'race' then interval '10 minutes' else interval '24 hours' end
    where id = c.id;
  insert into public.challenge_players (challenge_id, player) values (c.id, me) on conflict do nothing;
  return c.id;
end;
$$;

-- A player's page calls this every few seconds while waiting in a race's lobby. Once both players have checked in
-- within the last 15 seconds, the race starts 4 seconds later (the countdown) and has 10 minutes from then.
create function public.race_ready(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  c public.challenges;
  go timestamptz;
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  perform public.finalize_challenge(p_id);
  select * into c from public.challenges where id = p_id and mode = 'race' and me in (creator, opponent) for update;
  if not found then raise exception 'no such challenge' using errcode = 'JJ006'; end if;
  if c.status not in ('pending', 'active') then raise exception 'the challenge is over' using errcode = 'JJ007'; end if;
  update public.challenge_players set ready_at = now() where challenge_id = p_id and player = me;
  if c.status = 'active' and c.starts_at is null and (
      select count(*) from public.challenge_players
      where challenge_id = p_id and ready_at > now() - interval '15 seconds') = 2 then
    go := now() + interval '4 seconds';
    update public.challenges set starts_at = go, expires_at = go + interval '10 minutes' where id = p_id;
    update public.challenge_players set started_at = go where challenge_id = p_id;
  end if;
end;
$$;

-- Either player can call off a race that hasn't started yet (as well as the creator taking back an unaccepted challenge).
create or replace function public.cancel_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  perform public.finalize_challenge(p_id);
  update public.challenges set status = 'cancelled', finished_at = now()
    where id = p_id and (
      (creator = auth.uid() and status = 'pending')
      or (mode = 'race' and status = 'active' and starts_at is null and auth.uid() in (creator, opponent)));
  if not found then raise exception 'challenge unavailable' using errcode = 'JJ011'; end if;
end;
$$;

-- In a race the clock is the race's start, so opening it doesn't start anything.
create or replace function public.start_challenge(p_id uuid)
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
      and c.id = p.challenge_id and c.mode = 'async' and c.status in ('pending', 'active') and now() < c.expires_at;
end;
$$;

-- Giving up a race only makes sense once it has started.
create or replace function public.give_up_challenge(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  perform public.finalize_challenge(p_id);
  if exists (select 1 from public.challenges c
             where c.id = p_id and c.mode = 'race' and auth.uid() in (c.creator, c.opponent)
               and c.status in ('pending', 'active') and (c.starts_at is null or now() < c.starts_at)) then
    raise exception 'the race has not started' using errcode = 'JJ014';
  end if;
  update public.challenge_players p set finished_at = now(), gave_up = true, started_at = coalesce(p.started_at, now())
    from public.challenges c
    where p.challenge_id = p_id and p.player = auth.uid() and p.finished_at is null
      and c.id = p.challenge_id and c.status in ('pending', 'active') and now() < c.expires_at;
  if not found then raise exception 'the challenge is over' using errcode = 'JJ007'; end if;
  perform public.finalize_challenge(p_id);
end;
$$;

-- One challenge from your side. During a race the other player's colours and guess count show live
-- (not which characters they guessed), and whether they're in the lobby.
create or replace function public.get_challenge(p_id uuid)
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
    'now', now(),
    'mode', c.mode,
    'status', c.status,
    'role', case when c.creator = me then 'creator' else 'opponent' end,
    'opponent', (select jsonb_build_object('id', p.id, 'username', p.username) from public.profiles p where p.id = other),
    'link_code', case when c.creator = me then c.link_code end,
    'parts', c.parts,
    'max_guesses', c.max_guesses,
    'created_at', c.created_at,
    'starts_at', c.starts_at,
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
      when c.mode = 'race' then jsonb_build_object(
        'finished', theirs.finished_at is not null, 'gave_up', theirs.gave_up, 'guess_count', theirs.guess_count,
        'ready', coalesce(theirs.ready_at > now() - interval '15 seconds', false),
        -- one string of colours per guess: user, stand, gender, ability, type, side, affiliation, part
        'progress', coalesce((select jsonb_agg(concat(g.result->>'user', g.result->>'stand', g.result->>'gender', g.result->>'ability',
                                                      g.result->>'type', g.result->>'side', g.result->>'affiliation', g.result->>'part') order by g.n)
                              from public.challenge_guesses g where g.challenge_id = p_id and g.player = other), '[]'::jsonb))
      else jsonb_build_object('finished', theirs.finished_at is not null) end,
    'secret', case when reveal then s.char_id end,
    'hint', case when coalesce(mine.guess_count, 0) >= 8 or reveal then s.hint end,
    'result', case when c.status = 'finished' then
      case when c.winner is null then 'draw' when c.winner = me then 'win' else 'loss' end end
  );
end;
$$;

create or replace function public.list_challenges()
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
        'mode', c.mode,
        'status', c.status,
        'role', case when c.creator = me then 'creator' else 'opponent' end,
        'opponent', (select p.username from public.profiles p where p.id = case when c.creator = me then c.opponent else c.creator end),
        'link_code', case when c.creator = me then c.link_code end,
        'parts', c.parts,
        'max_guesses', c.max_guesses,
        'created_at', c.created_at,
        'starts_at', c.starts_at,
        'expires_at', c.expires_at,
        'my_started', mp.started_at is not null,
        'my_finished', mp.finished_at is not null,
        'their_finished', tp.finished_at is not null,
        'result', case when c.status = 'finished' then
          case when c.winner is null then 'draw' when c.winner = me then 'win' else 'loss' end end,
        'my_guesses', case when c.status = 'finished' then mp.guess_count end,
        'their_guesses', case when c.status = 'finished' then tp.guess_count end,
        'my_solved', case when c.status = 'finished' then mp.solved end,
        'their_solved', case when c.status = 'finished' then tp.solved end) as x
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

-- In a race, each guess pings the other player so their page can show the new colours.
create function public.on_challenge_guess()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.challenges;
begin
  select * into c from public.challenges where id = new.challenge_id;
  if c.mode = 'race' then
    perform public.notify_players('race', case when new.player = c.creator then c.opponent else c.creator end);
  end if;
  return null;
end;
$$;
create trigger challenge_guesses_notify after insert on public.challenge_guesses
  for each row execute function public.on_challenge_guess();

revoke execute on function public.on_challenge_guess() from public, anon, authenticated;
revoke execute on function public.race_ready(uuid) from public, anon;
grant execute on function public.race_ready(uuid) to authenticated;
