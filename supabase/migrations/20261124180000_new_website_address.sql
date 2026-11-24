-- The public website moved to https://puffle-web.vercel.app (owner's Vercel).
-- Web measurement accepts both addresses (old links in running ads keep working).
do $$
declare f regprocedure; d text;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('record_web_measurement', 'record_web_attribution')
              and pg_get_functiondef(p.oid) like '%^https://puffle-iota[.]vercel[.]app%' loop
    d := replace(pg_get_functiondef(f), '^https://puffle-iota[.]vercel[.]app', '^https://(puffle-iota|puffle-web)[.]vercel[.]app');
    execute d;
  end loop;
end $$;

alter table public.meta_settings alter column website_url set default 'https://puffle-web.vercel.app';
update public.meta_settings set website_url = 'https://puffle-web.vercel.app' where website_url = 'https://puffle-iota.vercel.app';
