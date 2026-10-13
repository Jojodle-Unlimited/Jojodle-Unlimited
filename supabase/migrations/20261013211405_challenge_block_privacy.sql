-- A blocked player challenging the blocker now hears "not friends" (blocking always ends a friendship),
-- the same as for anyone else, so the block stays private like it does for friend requests.
create or replace function public.sv_create_challenge(
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

  insert into public.challenges (creator, opponent, link_code, parts, max_guesses, rematch_of)
    values (p_creator, p_opponent, p_link_code, p_parts, p_max_guesses, p_rematch_of)
    returning id into new_id;
  insert into public.challenge_secrets (challenge_id, char_id, hint) values (new_id, p_char_id, p_hint);
  insert into public.challenge_players (challenge_id, player) values (new_id, p_creator);
  return new_id;
end;
$$;
