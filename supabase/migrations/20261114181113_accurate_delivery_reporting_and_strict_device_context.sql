create or replace function public.admin_meta_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501'; end if;
 return jsonb_build_object(
 'funnel',coalesce((select jsonb_agg(to_jsonb(r)) from(
 select e.event_name,count(*) filter(where created_at>now()-interval '1 day') as d1,count(*) filter(where created_at>now()-interval '7 days') as d7,count(*) as d30,
 count(*) filter(where status='sent') as sent,count(*) filter(where status='test_sent') as test_sent,count(*) filter(where status='failed') as failed,
 count(*) filter(where fbc is not null) as with_click,
 coalesce(sum(value_inr) filter(where event_name='Purchase' and status='sent' and created_at>now()-interval '7 days'),0) as value_d7,
 coalesce(sum(value_inr) filter(where event_name='Purchase' and status='sent'),0) as value_d30
 from public.meta_events e where created_at>now()-interval '30 days' group by event_name order by event_name)r),'[]'::jsonb),
 'recent',coalesce((select jsonb_agg(to_jsonb(r)) from(select id,event_name,status,value_inr,content_name,attempts,last_error,created_at,sent_at,action_source,meta_trace_id,
 (fbc is not null) as has_click from public.meta_events order by created_at desc limit 60)r),'[]'::jsonb),
 'clicks_7d',(select count(*) from public.ad_clicks where created_at>now()-interval '7 days'),
 'matched_installs_7d',0,'auto_send',(select url<>'' from private.meta_cron where id=1));
end $$;
create or replace function public.admin_meta_retry() returns integer language plpgsql security definer set search_path='' as $$
declare n integer;begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501'; end if;
 update public.meta_events e set status='pending',attempts=0,next_attempt_at=now(),lease_until=null
 where e.status='failed' and e.created_at>now()-interval '6 days' and e.advertising_consent
 and e.config_revision=(select revision from public.meta_settings where id=1)
 and(e.user_id is null or exists(select 1 from public.measurement_preferences p where p.user_id=e.user_id and p.advertising));
 get diagnostics n=row_count;perform private.meta_kick();return n;end $$;
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
  if coalesce(jsonb_typeof(ext),'')<>'array' or jsonb_array_length(ext)<>16 or ext->>0<>'a2' or ext->>1<>'com.pufflecloud.app'
     or coalesce(ext->>4,'')='' or coalesce(install_,'')!~'^[0-9a-f-]{36}$' then raise exception 'valid Android app context required'; end if;
  for i in 0..15 loop
   if coalesce(jsonb_typeof(ext->i),'')<>'string' or length(ext->>i)>120 then raise exception 'invalid app context'; end if;
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

