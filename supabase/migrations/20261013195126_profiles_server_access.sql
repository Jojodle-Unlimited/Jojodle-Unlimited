-- Server functions run as service_role. New tables aren't exposed automatically, so they need an explicit grant too.
grant select, insert, update, delete on table public.profiles to service_role;
