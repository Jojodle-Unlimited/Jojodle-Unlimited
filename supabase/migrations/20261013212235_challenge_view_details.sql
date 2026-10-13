-- get_challenge also sends the server's clock (the page's challenge timer then can't drift with a wrong device clock),
-- and list_challenges says who solved a finished challenge (so the list can say "not solved" rather than a guess count).
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
