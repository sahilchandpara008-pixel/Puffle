-- Account upgrades must take effect immediately even while an older guest JWT is still valid.
-- Keep the existing SECURITY DEFINER lookup, fixed search path and execution grants.
create or replace function public.is_member()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
    where u.id = auth.uid() and u.is_anonymous = false
  )
$$;
