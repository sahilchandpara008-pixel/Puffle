do $migration$
declare r record; body_ text;
begin
 for r in select oid,proname from pg_proc where pronamespace='public'::regnamespace and proname in('admin_users_filtered','admin_payments_filtered') loop
  body_:=pg_get_functiondef(r.oid);
  body_:=replace(body_,'coalesce(us.source,''organic'')',case when r.proname='admin_users_filtered' then 'private.source_of(pr.id)' else 'private.source_of(o.user_id)' end);
  execute body_;
 end loop;
end $migration$;

