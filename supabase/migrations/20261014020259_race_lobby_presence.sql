-- Being in a race's lobby is tighter: pages check in every 3 seconds and only the last 8 seconds count (it was 15),
-- and leaving the lobby (back to solo, another game) says so at once (race_unready), so a race never starts
-- without a player who just left.

-- A player's page calls this every few seconds while waiting in a race's lobby. Once both players have checked in
-- within the last 8 seconds, the race starts 4 seconds later (the countdown) and has 10 minutes from then.
create or replace function public.race_ready(p_id uuid)
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
      where challenge_id = p_id and ready_at > now() - interval '8 seconds') = 2 then
    go := now() + interval '4 seconds';
    update public.challenges set starts_at = go, expires_at = go + interval '10 minutes' where id = p_id;
    update public.challenge_players set started_at = go where challenge_id = p_id;
  end if;
end;
$$;

-- Leaving a race's lobby before the start: you're no longer counted as there.
create function public.race_unready(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  update public.challenge_players p set ready_at = null
    from public.challenges c
    where p.challenge_id = p_id and p.player = auth.uid() and c.id = p.challenge_id and c.mode = 'race' and c.starts_at is null;
end;
$$;
revoke execute on function public.race_unready(uuid) from public, anon;
grant execute on function public.race_unready(uuid) to authenticated;

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
        'ready', coalesce(theirs.ready_at > now() - interval '8 seconds', false),
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
