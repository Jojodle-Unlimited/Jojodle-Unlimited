-- A link's preview also says whether it's a live race, so the page can invite the visitor to race rather than take turns.
create or replace function public.peek_challenge(p_code text)
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
    'mode', c.mode,
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
