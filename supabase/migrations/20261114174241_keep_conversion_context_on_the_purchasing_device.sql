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
  coalesce(a.last_ip,a.ip),coalesce(a.last_ua,a.ua),name_,event_time_,
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
  perform private.touch_attribution(uid);
  if not coalesce(old_ads,false) then perform private.enqueue_meta('AppInstall',uid,null,null); end if;
 else
  update public.meta_events set status='suppressed',last_error='Advertising sharing disabled by the user',fbc=null,fbp=null,client_ip=null,client_ua=null,app_data=null,anon_id=null
   where user_id=uid and status in('pending','processing','failed');
  delete from private.app_measurement_context where user_id=uid;
  delete from private.user_attribution where user_id=uid;
  if not p_analytics then delete from private.app_activity where user_id=uid; end if;
 end if;
 return jsonb_build_object('analytics',p_analytics,'advertising',p_advertising,'policy_version','2026-11-14');
end $$;
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
 if pref.advertising then perform private.touch_attribution(uid); end if;
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
