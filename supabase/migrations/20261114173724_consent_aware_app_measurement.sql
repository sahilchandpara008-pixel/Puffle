
-- Consent-aware measurement. No advertising SDK, advertising ID, private content or client-supplied purchase amounts.
create table public.measurement_preferences(
 user_id uuid primary key references auth.users(id) on delete cascade,
 analytics boolean not null default false, advertising boolean not null default false,
 policy_version text not null default '2026-11-14', advertising_since timestamptz, updated_at timestamptz not null default now()
);
alter table public.measurement_preferences enable row level security;
create policy measurement_preferences_read on public.measurement_preferences for select to authenticated using(user_id=(select auth.uid()));
revoke all on public.measurement_preferences from anon,authenticated;
grant select on public.measurement_preferences to authenticated;
create table private.app_measurement_context(
 user_id uuid primary key references auth.users(id) on delete cascade,
 install_id text not null, app_data jsonb not null, updated_at timestamptz not null default now()
);
create table private.app_activity(
 event_id uuid primary key,user_id uuid not null references auth.users(id) on delete cascade,
 session_id uuid not null,event_name text not null,properties jsonb not null default '{}',
 occurred_at timestamptz not null,received_at timestamptz not null default now()
);
create index app_activity_user_time on private.app_activity(user_id,occurred_at desc);
create index app_activity_time on private.app_activity(occurred_at desc);
alter table private.app_measurement_context enable row level security;
alter table private.app_activity enable row level security;
alter table public.meta_settings add column revision bigint not null default 1;
alter table public.meta_events
 add column action_source text not null default 'app',
 add column app_data jsonb,
 add column anon_id text,
 add column custom_data jsonb not null default '{}',
 add column advertising_consent boolean not null default false,
 add column config_revision bigint not null default 1,
 add column lease_until timestamptz,
 add column next_attempt_at timestamptz not null default now(),
 add column meta_trace_id text;
alter table public.meta_events drop constraint if exists meta_events_event_name_check;
alter table public.meta_events drop constraint if exists meta_events_status_check;
alter table public.meta_events add constraint meta_events_status_check check(status in('pending','processing','sent','test_sent','failed','suppressed'));
alter table public.meta_events add constraint meta_events_action_source_check check(action_source in('website','app'));
create index meta_events_due on public.meta_events(next_attempt_at,created_at) where status in('pending','processing');
create or replace function private.meta_revision() returns trigger language plpgsql set search_path='' as $$
begin
 if new.pixel_id is distinct from old.pixel_id then
  new.revision:=old.revision+1;
  update public.meta_events set status='suppressed',last_error='Dataset changed; old events are not replayed to the new dataset'
   where status in('pending','processing');
 else new.revision:=old.revision;
 end if;
 return new;
end $$;
create trigger meta_settings_revision before update on public.meta_settings for each row execute function private.meta_revision();

create or replace function private.enqueue_meta(p_event text,p_user uuid,p_order uuid,p_value numeric) returns void
language plpgsql security definer set search_path='' as $$
declare pref public.measurement_preferences%rowtype; ctx private.app_measurement_context%rowtype;
 a private.user_attribution%rowtype; o public.payment_orders%rowtype; event_time_ timestamptz:=now(); key_ text; value_ numeric; name_ text;
begin
 if not private.meta_ready() then return; end if;
 select * into pref from public.measurement_preferences where user_id=p_user;
 if not coalesce(pref.advertising,false) then return; end if;
 select * into ctx from private.app_measurement_context where user_id=p_user;
 if ctx.user_id is null then return; end if;
 select * into a from private.user_attribution where user_id=p_user;
 if p_event in('Purchase','InitiateCheckout') then
  select * into o from public.payment_orders where id=p_order and user_id=p_user;
  if o.id is null then return; end if;
  if p_event='Purchase' and (o.status<>'paid' or not o.bank_verified) then return; end if;
  value_:=o.amount_paise/100.0; name_:=o.plan_name;
  event_time_:=case when p_event='Purchase' then o.activated_at else o.created_at end;
  if event_time_ is null or event_time_<coalesce(pref.advertising_since,pref.updated_at) or event_time_<now()-interval '7 days' then return; end if;
  key_:=case when p_event='Purchase' then 'purchase-' else 'checkout-' end||p_order::text;
 elsif p_event='AppInstall' then
  select created_at into event_time_ from public.installs where user_id=p_user and install_id=ctx.install_id;
  if event_time_ is null or event_time_<now()-interval '1 day' then return; end if;
  key_:='install-'||ctx.install_id;
 elsif p_event='CompleteRegistration' then key_:='reg-'||p_user::text;
 else return;
 end if;
 insert into public.meta_events(event_name,event_id,user_id,order_id,value_inr,fbc,fbp,client_ip,client_ua,content_name,created_at,
  action_source,app_data,anon_id,advertising_consent,config_revision,custom_data)
 values(case when p_event='AppInstall' then 'MobileAppInstall' else p_event end,key_,p_user,p_order,value_,a.fbc,a.fbp,
  private.req_ip(),left(private.req_header('user-agent'),400),name_,event_time_,
  'app',ctx.app_data,ctx.install_id,true,(select revision from public.meta_settings where id=1),
  case when p_order is null then '{}'::jsonb else jsonb_build_object('order_id',p_order::text) end)
 on conflict(event_id) do nothing;
end $$;

create or replace function public.set_measurement_preferences(p_analytics boolean,p_advertising boolean,p_context jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); ext jsonb; install_ text; old_ads boolean; i int; was_recorded boolean;
begin
 if uid is null then raise exception 'session required' using errcode='42501'; end if;
 select advertising into old_ads from public.measurement_preferences where user_id=uid;
 was_recorded:=found;
 insert into public.measurement_preferences(user_id,analytics,advertising,advertising_since) values(uid,p_analytics,p_advertising,case when p_advertising then now() end)
 on conflict(user_id) do update set analytics=excluded.analytics,advertising=excluded.advertising,policy_version='2026-11-14',updated_at=now(),
 advertising_since=case when not excluded.advertising then null when measurement_preferences.advertising then measurement_preferences.advertising_since else now() end;
 if p_advertising then
  ext:=p_context->'extinfo'; install_:=p_context->>'install_id';
  if jsonb_typeof(ext)<>'array' or jsonb_array_length(ext)<>16 or ext->>0<>'a2' or ext->>1<>'com.pufflecloud.app'
     or coalesce(ext->>4,'')='' or coalesce(install_,'')!~'^[0-9a-f-]{36}$' then raise exception 'valid Android app context required'; end if;
  for i in 0..15 loop
   if jsonb_typeof(ext->i)<>'string' or length(ext->>i)>120 then raise exception 'invalid app context'; end if;
  end loop;
  insert into private.app_measurement_context(user_id,install_id,app_data)
  values(uid,install_,jsonb_build_object('advertiser_tracking_enabled',1,'application_tracking_enabled',1,'extinfo',ext))
  on conflict(user_id) do update set install_id=excluded.install_id,app_data=excluded.app_data,updated_at=now();
  if not coalesce(old_ads,false) then perform private.enqueue_meta('AppInstall',uid,null,null); end if;
 else
  update public.meta_events set status='suppressed',last_error='Advertising sharing disabled by the user',fbc=null,fbp=null,client_ip=null,client_ua=null,app_data=null,anon_id=null
   where user_id=uid and status in('pending','processing','failed');
  delete from private.app_measurement_context where user_id=uid;
  delete from private.user_attribution where user_id=uid;
 end if;
 return jsonb_build_object('analytics',p_analytics,'advertising',p_advertising,'policy_version','2026-11-14');
end $$;
revoke all on function public.set_measurement_preferences(boolean,boolean,jsonb) from public,anon;
grant execute on function public.set_measurement_preferences(boolean,boolean,jsonb) to authenticated;

create or replace function public.record_activity(p_event_id uuid,p_name text,p_session_id uuid,p_properties jsonb default '{}',p_occurred_at timestamptz default now())
returns boolean language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); pref public.measurement_preferences%rowtype; ctx private.app_measurement_context%rowtype; props jsonb; at_ timestamptz;
begin
 if uid is null then raise exception 'session required' using errcode='42501'; end if;
 if p_name not in('AppOpen','ScreenView','Login','ViewContent','VideoStart','VideoProgress','PreviewComplete','SearchUsed','ChannelCreated','ChannelJoined','VideoUploaded','CloudUploaded','CloudDeleted','PlanViewed','SubscriptionPrompt') then
  raise exception 'event is not permitted'; end if;
 select * into pref from public.measurement_preferences where user_id=uid;
 if not coalesce(pref.analytics,false) and not coalesce(pref.advertising,false) then return false; end if;
 if (select count(*) from private.app_activity where user_id=uid and received_at>now()-interval '1 day')>=5000 then return false; end if;
 at_:=greatest(now()-interval '1 day',least(coalesce(p_occurred_at,now()),now()));
 props:=jsonb_strip_nulls(jsonb_build_object(
 'screen',case when p_properties->>'screen' in('Cloud','Home','Explore','Channel','Profile','Premium','Post','Safety') then p_properties->>'screen' end,
 'media_type',case when p_properties->>'media_type' in('video','image','file') then p_properties->>'media_type' end,
 'progress',case when p_properties->>'progress' in('25','50','75','100') then (p_properties->>'progress')::int end,
 'preview',case when jsonb_typeof(p_properties->'preview')='boolean' then p_properties->'preview' end,
 'premium',case when jsonb_typeof(p_properties->'premium')='boolean' then p_properties->'premium' end));
 -- Store one minimal activity row for deduplication/consented analytics, never arbitrary text or content identifiers.
 insert into private.app_activity(event_id,user_id,session_id,event_name,properties,occurred_at) values(p_event_id,uid,p_session_id,p_name,props,at_)
 on conflict(event_id) do nothing;
 if not found then return false; end if;
 if pref.advertising and private.meta_ready() then
  select * into ctx from private.app_measurement_context where user_id=uid;
  if ctx.user_id is not null then
   insert into public.meta_events(event_name,event_id,user_id,created_at,action_source,app_data,anon_id,advertising_consent,config_revision,custom_data,client_ip,client_ua)
   values(p_name,'activity-'||p_event_id::text,uid,at_,'app',ctx.app_data,ctx.install_id,true,
    (select revision from public.meta_settings where id=1),props,private.req_ip(),left(private.req_header('user-agent'),400)) on conflict(event_id) do nothing;
  end if;
 end if;
 return true;
end $$;
revoke all on function public.record_activity(uuid,text,uuid,jsonb,timestamptz) from public,anon;
grant execute on function public.record_activity(uuid,text,uuid,jsonb,timestamptz) to authenticated;

-- Preserve install classification and content access; remove the unreliable same-IP ad-click guess.
create or replace function public.record_install(p_install_id text,p_referrer_status text,p_raw_referrer text,p_install_secret text)
returns text language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); norm text; src text; existing text;
begin
 if uid is null then raise exception 'not authenticated' using errcode='28000'; end if;
 if p_install_id is null or length(p_install_id) not between 8 and 100 then raise exception 'invalid install id'; end if;
 select source into existing from private.user_sources where user_id=uid;
 if existing is not null then return existing; end if;
 norm:=replace(replace(lower(coalesce(p_raw_referrer,'')),'%3d','='),'%26','&');
 src:=case when norm~'(^|[&?])utm_source=(meta|facebook|instagram|ig)(&|$)' then 'ads' else 'organic' end;
 insert into public.installs(install_id,user_id,source,referrer_status,raw_referrer,utm_campaign,install_secret)
 values(p_install_id,uid,src,left(p_referrer_status,100),
  case when src='ads' then 'utm_source=meta' else '' end,null,left(p_install_secret,200)) on conflict(install_id) do nothing;
 insert into private.user_sources(user_id,source) values(uid,src) on conflict(user_id) do nothing;
 return src;
end $$;
create or replace function private.touch_attribution(p_user uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.measurement_preferences where user_id=p_user and advertising) then
  insert into private.user_attribution(user_id,last_ip,last_ua) values(p_user,private.req_ip(),left(private.req_header('user-agent'),400))
  on conflict(user_id) do update set last_ip=excluded.last_ip,last_ua=excluded.last_ua,updated_at=now();
 end if;
end $$;
-- A successful UPI app reply keeps its existing activation flow; Meta Purchase waits for bank/provider verification.
create or replace function private.verified_purchase_event() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='paid' and new.bank_verified and (old.status is distinct from new.status or not old.bank_verified) then
  perform private.enqueue_meta('Purchase',new.user_id,new.id,new.amount_paise/100.0);
 end if;
 if new.status in('revoked','rejected','failed','cancelled') then
  update public.meta_events set status='suppressed',last_error='Order is no longer a paid verified purchase'
   where order_id=new.id and event_name='Purchase' and status in('pending','processing','failed');
 end if;
 return new;
end $$;
create trigger verified_purchase_measurement after update on public.payment_orders for each row execute function private.verified_purchase_event();

-- Old public website calls cannot share advertising data without the updated consent flow.
create or replace function public.record_ad_click(p_fbclid text,p_fbc text,p_fbp text,p_url text,p_lead_event_id text default null)
returns uuid language sql set search_path='' as $$ select null::uuid $$;
create or replace function public.record_web_measurement(p_event text,p_event_id uuid,p_consent boolean,p_fbclid text default '',p_fbc text default '',p_fbp text default '',p_url text default '')
returns boolean language plpgsql security definer set search_path='' as $$
declare ip_ text:=private.req_ip(); fbc_ text; rev bigint;
begin
 if not p_consent or not private.meta_ready() or ip_ is null then return false; end if;
 if p_event not in('PageView','Lead','PlanViewed') then raise exception 'event is not permitted'; end if;
 if p_url!~'^https://puffle-iota[.]vercel[.]app(/[^?#]*)?$' then return false; end if;
 if (select count(*) from public.meta_events where client_ip=ip_ and action_source='website' and created_at>now()-interval '1 hour')>=120 then return false; end if;
 fbc_:=coalesce(nullif(left(p_fbc,600),''),case when coalesce(p_fbclid,'')<>'' then 'fb.1.'||(extract(epoch from now())*1000)::bigint||'.'||left(p_fbclid,500) end);
 select revision into rev from public.meta_settings where id=1;
 insert into public.meta_events(event_name,event_id,action_source,advertising_consent,config_revision,fbc,fbp,client_ip,client_ua,source_url,custom_data)
 values(p_event,'web-'||p_event_id::text,'website',true,rev,fbc_,nullif(left(p_fbp,200),''),ip_,left(private.req_header('user-agent'),400),left(p_url,500),
 case when p_event='Lead' then '{"content_name":"apk_download"}'::jsonb else '{}'::jsonb end) on conflict(event_id) do nothing;
 return found;
end $$;
revoke all on function public.record_web_measurement(text,uuid,boolean,text,text,text,text) from public;
grant execute on function public.record_web_measurement(text,uuid,boolean,text,text,text,text) to anon,authenticated;
-- Atomic leasing prevents the cron and an admin-triggered flush from delivering the same batch concurrently.
create or replace function public.meta_claim_batch(p_limit int default 50) returns setof public.meta_events
language plpgsql security definer set search_path='' as $$
begin
 update public.meta_events e set status='suppressed',last_error='Consent withdrawn, configuration changed, or event expired'
 where e.status in('pending','processing') and (
  not e.advertising_consent or e.config_revision<>(select revision from public.meta_settings where id=1)
  or e.created_at<now()-interval '7 days'
  or(e.user_id is not null and not exists(select 1 from public.measurement_preferences p where p.user_id=e.user_id and p.advertising)));
 return query with picked as(
  select e.id from public.meta_events e where
   ((e.status='pending' and e.next_attempt_at<=now()) or(e.status='processing' and e.lease_until<now()))
   and e.attempts<8 order by e.created_at for update skip locked limit least(greatest(p_limit,1),100))
 update public.meta_events e set status='processing',lease_until=now()+interval '5 minutes',attempts=e.attempts+1
 from picked p where e.id=p.id returning e.*;
end $$;
revoke all on function public.meta_claim_batch(int) from public,anon,authenticated;
grant execute on function public.meta_claim_batch(int) to service_role;
select cron.schedule('measurement-retention','17 3 * * *',$job$
 delete from private.app_activity where received_at<now()-interval '90 days';
 delete from public.meta_events where created_at<now()-interval '90 days';
 delete from public.ad_clicks where created_at<now()-interval '30 days';
 update private.user_attribution set fbc=null,fbp=null,ip=null,ua=null,last_ip=null,last_ua=null,click_id=null where updated_at<now()-interval '30 days';
$job$);

