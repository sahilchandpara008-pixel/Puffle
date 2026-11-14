CREATE OR REPLACE FUNCTION public.admin_users_filtered(p_search text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_plan text DEFAULT NULL::text, p_guest boolean DEFAULT NULL::boolean, p_access text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_customer text DEFAULT NULL::text, p_sort text DEFAULT 'newest'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result_ jsonb;
begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501'; end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Start date must not follow end date'; end if;
 with spending as (
  select user_id,count(*) as paid_orders,sum(amount_paise)/100.0 as spent,
  coalesce(sum(amount_paise) filter(where bank_verified),0)/100.0 as verified_spent
  from public.payment_orders where status='paid' group by user_id),
 activity as(select user_id,max(occurred_at) as last_seen,count(distinct session_id) as sessions from private.app_activity a join public.measurement_preferences pref using(user_id) where pref.analytics group by user_id),
 base as(
  select pr.id,u.email,pr.display_name,pr.is_guest,coalesce(us.source,'organic') as source,pr.ads_access_status,pr.used_bytes,pr.created_at,
  current_plan.plan_name,current_plan.plan_ends_at,coalesce(s.paid_orders,0) as paid_orders,coalesce(s.spent,0) as spent,
  coalesce(s.verified_spent,0) as verified_spent,a.last_seen,coalesce(a.sessions,0) as sessions
  from public.profiles pr join auth.users u on u.id=pr.id left join private.user_sources us on us.user_id=pr.id
  left join spending s on s.user_id=pr.id left join activity a on a.user_id=pr.id
  left join lateral(select plan_name,ends_at as plan_ends_at from public.subscriptions where user_id=pr.id and not revoked and ends_at>now() order by ends_at desc limit 1) current_plan on true
  where (nullif(p_search,'') is null or u.email ilike '%'||left(p_search,200)||'%' or pr.display_name ilike '%'||left(p_search,200)||'%' or pr.id::text=p_search)
  and(nullif(p_source,'') is null or coalesce(us.source,'organic')=p_source)
  and(p_guest is null or pr.is_guest=p_guest)
  and(nullif(p_access,'') is null or pr.ads_access_status=p_access)
  and(p_from is null or pr.created_at>=p_from::timestamp at time zone 'Asia/Kolkata')
  and(p_to is null or pr.created_at<(p_to+1)::timestamp at time zone 'Asia/Kolkata')),
 filtered as(select * from base where
  (nullif(p_plan,'') is null or(p_plan='active' and plan_name is not null) or(p_plan='none' and plan_name is null))
  and(nullif(p_customer,'') is null or(p_customer='repeat' and paid_orders>=2) or(p_customer='first' and paid_orders=1) or(p_customer='never' and paid_orders=0) or(p_customer='returning' and sessions>=2))),
 sorted as(select * from filtered order by
  case when p_sort='oldest' then created_at end asc nulls last,
  case when p_sort='spent_high' then spent end desc nulls last,
  case when p_sort='spent_low' then spent end asc nulls last,
  case when p_sort='recently_active' then last_seen end desc nulls last,
  case when p_sort='repeat' then paid_orders end desc nulls last,
  created_at desc,id
  limit least(greatest(p_limit,1),200) offset greatest(p_offset,0))
 select jsonb_build_object('total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(s)) from sorted s),'[]'::jsonb)) into result_;
 return result_;
end $function$;

CREATE OR REPLACE FUNCTION public.record_activity(p_event_id uuid, p_name text, p_session_id uuid, p_properties jsonb DEFAULT '{}'::jsonb, p_occurred_at timestamp with time zone DEFAULT now())
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 if pref.advertising and at_>=coalesce(pref.advertising_since,pref.updated_at) and private.meta_ready() then
  select * into ctx from private.app_measurement_context where user_id=uid;
  if ctx.user_id is not null then
   insert into public.meta_events(event_name,event_id,user_id,created_at,action_source,app_data,anon_id,advertising_consent,config_revision,custom_data,client_ip,client_ua)
   values(p_name,'activity-'||p_event_id::text,uid,at_,'app',ctx.app_data,ctx.install_id,true,
    (select revision from public.meta_settings where id=1),props,private.req_ip(),left(private.req_header('user-agent'),400)) on conflict(event_id) do nothing;
  end if;
 end if;
 return true;
end $function$;
