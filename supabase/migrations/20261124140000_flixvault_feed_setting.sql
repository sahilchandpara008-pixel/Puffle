-- Where Flixvault's partner feed lives. Stored as a setting (not in code); the
-- value is set by the owner/operator. Readable only by Puffle's server functions.
create table if not exists private.flixvault_settings (
  id       int primary key default 1 check (id = 1),
  feed_url text
);
insert into private.flixvault_settings (id) values (1) on conflict do nothing;

create or replace function public.flixvault_feed_url()
returns text language sql stable security definer set search_path = '' as $$
  select feed_url from private.flixvault_settings where id = 1
$$;
revoke execute on function public.flixvault_feed_url() from public, anon, authenticated;
grant execute on function public.flixvault_feed_url() to service_role;
