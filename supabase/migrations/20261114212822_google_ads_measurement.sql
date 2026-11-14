-- Google website tags and native Firebase are separate destinations. No secrets in public settings.
create table public.google_settings (
 id int primary key default 1 check(id=1), web_enabled boolean not null default false,
 web_method text not null default 'direct' check(web_method in('direct','gtm')),
 conversion_id text not null default '', download_label text not null default '', gtm_id text not null default '',
 app_enabled boolean not null default false, firebase_app_id text not null default '', firebase_project_id text not null default '',
 firebase_api_key text not null default '', firebase_sender_id text not null default '', api_secret text not null default '',
 ads_customer_id text not null default '', play_url text not null default '',
 accounts_linked boolean not null default false, conversions_imported boolean not null default false,
 test_mode boolean not null default true, revision bigint not null default 1, updated_at timestamptz not null default now()
);
insert into public.google_settings(id) values(1);
alter table public.google_settings enable row level security;
create policy google_settings_owner on public.google_settings for all to authenticated using(public.is_owner()) with check(public.is_owner());
revoke all on public.google_settings from anon,authenticated;grant select,update on public.google_settings to authenticated;
create table public.google_preferences(
 user_id uuid primary key references auth.users(id) on delete cascade, enabled boolean not null default false,
 enabled_since timestamptz, updated_at timestamptz not null default now()
);
alter table public.google_preferences enable row level security;
create policy google_preferences_self on public.google_preferences for select to authenticated using(user_id=(select auth.uid()));
revoke all on public.google_preferences from anon,authenticated;grant select on public.google_preferences to authenticated;
create table private.google_app_context(
 user_id uuid primary key references auth.users(id) on delete cascade, app_instance_id text not null,
 firebase_app_id text not null, session_id bigint, revision bigint not null, updated_at timestamptz not null default now()
);
alter table private.google_app_context enable row level security;
create table public.google_events(
 id bigint generated always as identity primary key,event_id text not null unique,user_id uuid references auth.users(id) on delete cascade,
 order_id uuid not null references public.payment_orders(id) on delete cascade, firebase_app_id text not null, app_instance_id text,
 session_id bigint,revision bigint not null,created_at timestamptz not null,queued_at timestamptz not null default now(),
 status text not null default 'pending' check(status in('pending','processing','submitted','validated','failed','suppressed')),
 attempts int not null default 0,lease_until timestamptz,next_attempt_at timestamptz not null default now(),last_error text,submitted_at timestamptz
);
alter table public.google_events enable row level security;
create policy google_events_owner on public.google_events for select to authenticated using(public.is_owner());
revoke all on public.google_events from anon,authenticated;grant select on public.google_events to authenticated;
create index google_events_due on public.google_events(next_attempt_at) where status in('pending','processing');
create or replace function private.google_revision() returns trigger language plpgsql set search_path='' as $$
begin
 if new.firebase_app_id is distinct from old.firebase_app_id then
  new.revision:=old.revision+1;
  update public.google_events set status='suppressed',last_error='Firebase destination changed' where status in('pending','processing','failed');
 else new.revision:=old.revision;end if;
 new.updated_at:=now();return new;end $$;
create trigger google_settings_revision before update on public.google_settings for each row execute function private.google_revision();

create or replace function public.google_public() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('web_enabled',web_enabled,'web_method',web_method,'conversion_id',conversion_id,'download_label',download_label,'gtm_id',gtm_id,
 'app_enabled',app_enabled,'firebase_app_id',firebase_app_id,'firebase_project_id',firebase_project_id,'firebase_api_key',firebase_api_key,
 'firebase_sender_id',firebase_sender_id,'revision',revision) from public.google_settings where id=1
$$;
revoke all on function public.google_public() from public;grant execute on function public.google_public() to anon,authenticated;

create or replace function public.set_google_preferences(p_enabled boolean,p_app_instance_id text default null,p_firebase_app_id text default null,p_session_id bigint default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();s public.google_settings%rowtype;
begin
 if uid is null then raise exception 'session required' using errcode='42501';end if;
 insert into public.google_preferences(user_id,enabled,enabled_since) values(uid,p_enabled,case when p_enabled then now() end)
 on conflict(user_id) do update set enabled=excluded.enabled,enabled_since=case when not excluded.enabled then null when google_preferences.enabled then google_preferences.enabled_since else now() end,updated_at=now();
 if not p_enabled then
  delete from private.google_app_context where user_id=uid;
  update public.google_events set status='suppressed',app_instance_id=null,last_error='Google sharing disabled by user' where user_id=uid and status in('pending','processing','failed');
 elsif p_app_instance_id is not null then
  select * into s from public.google_settings where id=1;
  if not s.app_enabled or p_firebase_app_id<>s.firebase_app_id or p_app_instance_id!~'^[a-fA-F0-9]{32}$' then raise exception 'valid Firebase app context required';end if;
  insert into private.google_app_context(user_id,app_instance_id,firebase_app_id,session_id,revision) values(uid,p_app_instance_id,p_firebase_app_id,case when p_session_id>0 then p_session_id end,s.revision)
  on conflict(user_id) do update set app_instance_id=excluded.app_instance_id,firebase_app_id=excluded.firebase_app_id,session_id=excluded.session_id,revision=excluded.revision,updated_at=now();
 end if;return true;
end $$;
revoke all on function public.set_google_preferences(boolean,text,text,bigint) from public,anon;grant execute on function public.set_google_preferences(boolean,text,text,bigint) to authenticated;

create or replace function private.google_verified_purchase() returns trigger language plpgsql security definer set search_path='' as $$
declare s public.google_settings%rowtype;c private.google_app_context%rowtype;p public.google_preferences%rowtype;
begin
 if new.status<>'paid' or not new.bank_verified then
  update public.google_events set status='suppressed',last_error='Order is no longer verified and paid' where order_id=new.id and status in('pending','processing','failed');return new;
 end if;
 select * into s from public.google_settings where id=1;
 if not s.app_enabled or s.firebase_app_id='' or s.api_secret='' then return new;end if;
 select * into p from public.google_preferences where user_id=new.user_id;
 if not coalesce(p.enabled,false) or new.activated_at<p.enabled_since or new.activated_at<now()-interval '72 hours' then return new;end if;
 select * into c from private.google_app_context where user_id=new.user_id and revision=s.revision and firebase_app_id=s.firebase_app_id;
 if c.user_id is null then return new;end if;
 insert into public.google_events(event_id,user_id,order_id,firebase_app_id,app_instance_id,session_id,revision,created_at)
 values('purchase-'||new.id::text,new.user_id,new.id,s.firebase_app_id,c.app_instance_id,c.session_id,s.revision,new.activated_at) on conflict(event_id) do nothing;
 return new;
end $$;
create trigger google_verified_purchase after update on public.payment_orders for each row execute function private.google_verified_purchase();

create or replace function public.google_claim_batch(p_limit int default 20) returns setof public.google_events language plpgsql security definer set search_path='' as $$
begin
 update public.google_events e set status='suppressed',last_error='Expired, destination changed, or permission withdrawn'
 where status in('pending','processing','failed') and(created_at<now()-interval '72 hours' or revision<>(select revision from public.google_settings where id=1)
 or not exists(select 1 from public.google_preferences p where p.user_id=e.user_id and p.enabled));
 return query with due as(select id from public.google_events where attempts<8 and next_attempt_at<=now() and(status='pending' or(status='processing' and lease_until<now())) order by created_at for update skip locked limit least(greatest(p_limit,1),50))
 update public.google_events e set status='processing',lease_until=now()+interval '5 minutes',attempts=attempts+1 from due where e.id=due.id returning e.*;
end $$;
revoke all on function public.google_claim_batch(int) from public,anon,authenticated;grant execute on function public.google_claim_batch(int) to service_role;

create or replace function public.admin_google_report() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501';end if;
 return jsonb_build_object('counts',coalesce((select jsonb_object_agg(status,n) from(select status,count(*)n from public.google_events where queued_at>now()-interval '30 days' group by status)r),'{}'::jsonb),
 'recent',coalesce((select jsonb_agg(to_jsonb(r)) from(select id,status,attempts,created_at,submitted_at,last_error from public.google_events order by id desc limit 40)r),'[]'::jsonb),
 'devices',(select count(*) from private.google_app_context where revision=(select revision from public.google_settings where id=1)));
end $$;
revoke all on function public.admin_google_report() from public,anon;grant execute on function public.admin_google_report() to authenticated;

-- Same private cron credential as the existing owner-authenticated measurement worker.
select cron.schedule('google-events-send','* * * * *',$cron$
 select net.http_post(url:=replace(url,'/meta-send','/google-send'),headers:=jsonb_build_object('content-type','application/json','x-cron-key',key),body:='{"action":"flush"}'::jsonb)
 from private.meta_cron where id=1 and url<>'' and exists(select 1 from public.google_settings where id=1 and app_enabled and api_secret<>'');
$cron$);
select cron.schedule('google-measurement-retention','27 3 * * *',$cron$
 delete from public.google_events where queued_at<now()-interval '90 days';delete from private.google_app_context where updated_at<now()-interval '90 days';
$cron$);
