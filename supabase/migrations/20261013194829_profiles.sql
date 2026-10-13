-- One profile per account: the public username friends and opponents see.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  created_at timestamptz not null default now()
);

-- usernames are unique regardless of capitalisation
create unique index profiles_username_lower_key on public.profiles (lower(username));

alter table public.profiles enable row level security;

-- New tables aren't exposed automatically, so grant exactly what the site needs.
-- Signed-in players can look up usernames (needed to find friends); signed-out visitors get nothing.
grant select on table public.profiles to authenticated;
grant insert (id, username) on table public.profiles to authenticated;
grant update (username) on table public.profiles to authenticated;

create policy "signed-in players can see profiles" on public.profiles
  for select to authenticated using (true);

create policy "players create their own profile" on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));

create policy "players rename their own profile" on public.profiles
  for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
