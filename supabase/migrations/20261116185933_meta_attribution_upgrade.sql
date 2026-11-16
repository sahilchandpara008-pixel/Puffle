-- Extends the deployed Puffle schema; acquisition metadata does not rewrite existing access grants.
alter table public.meta_settings
 add column website_url text not null default 'https://puffle-iota.vercel.app',
 add column store_url text not null default 'https://play.google.com/store/apps/details?id=com.pufflecloud.app',
 add column page_title text not null default 'Puffle',
 add column page_subtitle text not null default 'Your cloud and channels',
 add column action_source text not null default 'website' check(action_source in('website','app')),
 add column validation_status text not null default 'unconfigured';
alter table public.meta_events add column response jsonb;
alter table public.ad_clicks
 add column event_id uuid unique,
 add column utm_source text, add column utm_medium text,
 add column utm_campaign text, add column utm_content text, add column page_url text;
alter table public.installs
 add column attribution_source text not null default 'unknown',
 add column confidence integer not null default 0,
 add column utm_source text, add column utm_medium text, add column utm_content text, add column utm_term text,
 add column click_ts timestamptz, add column install_ts timestamptz,
 add column updated_at timestamptz not null default now();
alter table private.user_attribution
 add column first_touch jsonb, add column last_touch jsonb,
 add column first_touch_at timestamptz, add column last_touch_at timestamptz;

create function public.meta_landing_public() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('store_url',store_url,'page_title',page_title,'page_subtitle',page_subtitle) from public.meta_settings where id=1
$$;
revoke all on function public.meta_landing_public() from public;
grant execute on function public.meta_landing_public() to anon,authenticated;

create function private.meta_source() returns text language sql immutable set search_path='' as $$ select 'meta'::text $$;
create function private.url_decode(p_value text) returns text language plpgsql immutable set search_path='' as $$
declare v text:=replace(coalesce(p_value,''),'+',' '); b bytea:=''::bytea; i integer:=1; c text;
begin
 while i<=length(v) loop
  c:=substr(v,i,1);
  if c='%' and substr(v,i+1,2)~'^[0-9a-fA-F]{2}$' then b:=b||decode(substr(v,i+1,2),'hex');i:=i+3;
  else b:=b||convert_to(c,'UTF8');i:=i+1;end if;
 end loop;
 begin return convert_from(b,'UTF8');exception when character_not_in_repertoire then return v;end;
end $$;
create function private.parse_referrer(p_raw text) returns jsonb language plpgsql immutable set search_path='' as $$
declare raw_ text:=left(coalesce(p_raw,''),2048); item text; key_ text; value_ text; result_ jsonb:='{}';
begin
 if raw_ not like '%=%' and raw_~*'%3d' then raw_:=private.url_decode(raw_);end if;
 foreach item in array string_to_array(ltrim(raw_,'?'),'&') loop
  key_:=lower(private.url_decode(split_part(item,'=',1)));
  if key_ in('utm_source','utm_medium','utm_campaign','utm_content','utm_term') and not result_?key_ then
   value_:=left(private.url_decode(substr(item,strpos(item,'=')+1)),200);
   if key_ in('utm_source','utm_medium') then value_:=lower(trim(value_));end if;
   result_:=result_||jsonb_build_object(key_,value_);
  end if;
 end loop;
 return result_;
end $$;
create function private.classify_referrer(p_raw text,p_status text) returns text language plpgsql immutable set search_path='' as $$
declare p jsonb:=private.parse_referrer(p_raw); s text:=p->>'utm_source';m text:=p->>'utm_medium';
begin
 if s=private.meta_source() or s in('facebook','instagram','ig','fb') then return private.meta_source();end if;
 if s='google-play' and m='organic' then return 'organic';end if;
 if coalesce(trim(p_raw),'')='' then return case when p_status='direct' then 'direct' else 'unknown' end;end if;
 if s is not null then return 'other';end if;
 return 'unknown';
end $$;
revoke all on function private.meta_source(),private.url_decode(text),private.parse_referrer(text),private.classify_referrer(text,text) from public,anon,authenticated;

-- The legacy RPC stays available for installed 1.0.12 clients.
create function public.record_install_attribution(p_install_id text,p_referrer_status text,p_raw_referrer text,p_install_secret text,p_click_ts bigint default null,p_install_ts bigint default null)
returns text language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p jsonb; kind text; rank_ integer; src text; r public.installs%rowtype; touch_ jsonb; at_ timestamptz; t timestamptz;
begin
 if uid is null then raise exception 'session required' using errcode='42501';end if;
 if p_install_id is null or length(p_install_id) not between 8 and 100 or length(coalesce(p_install_secret,'')) not between 16 and 200 then raise exception 'invalid install identity';end if;
 if length(coalesce(p_raw_referrer,''))>2048 then raise exception 'referrer too long';end if;
 p:=private.parse_referrer(p_raw_referrer);kind:=private.classify_referrer(p_raw_referrer,p_referrer_status);
 rank_:=case when p_referrer_status='play_ok' and kind<>'unknown' then 30 when p_referrer_status='apk_define' then 20 when kind='direct' then 10 else 0 end;
 -- This is reported acquisition, not cryptographic proof of a paid ad. Preserve existing server access decisions.
 src:=case when kind=private.meta_source() or (p->>'utm_source' in('google','google_ads') and p->>'utm_medium' in('cpc','ppc','paid','paid_search')) then 'ads' else 'organic' end;
 t:=case when p_install_ts between 1000000000 and extract(epoch from now()+interval '1 day') then to_timestamp(p_install_ts) else now() end;
 insert into public.installs(install_id,user_id,source,referrer_status,raw_referrer,install_secret,attribution_source,confidence,utm_source,utm_medium,utm_campaign,utm_content,utm_term,click_ts,install_ts)
 values(p_install_id,uid,src,left(p_referrer_status,100),left(p_raw_referrer,2048),p_install_secret,kind,rank_,p->>'utm_source',p->>'utm_medium',p->>'utm_campaign',p->>'utm_content',p->>'utm_term',
 case when p_click_ts between 1000000000 and extract(epoch from t) then to_timestamp(p_click_ts) end,t)
 on conflict(install_id) do update set
 source=excluded.source,referrer_status=excluded.referrer_status,raw_referrer=excluded.raw_referrer,attribution_source=excluded.attribution_source,confidence=excluded.confidence,
 utm_source=excluded.utm_source,utm_medium=excluded.utm_medium,utm_campaign=excluded.utm_campaign,utm_content=excluded.utm_content,utm_term=excluded.utm_term,
 click_ts=excluded.click_ts,install_ts=excluded.install_ts,updated_at=now()
 where installs.install_secret=excluded.install_secret and excluded.confidence>installs.confidence;
 select * into r from public.installs where install_id=p_install_id;
 if r.install_secret is distinct from p_install_secret then raise exception 'install identity conflict' using errcode='42501';end if;
 insert into private.user_sources(user_id,source) values(uid,r.source) on conflict(user_id) do nothing;
 at_:=coalesce(r.install_ts,r.created_at);
 touch_:=jsonb_build_object('source',r.attribution_source,'medium',r.utm_medium,'campaign',r.utm_campaign,'content',r.utm_content,'term',r.utm_term,'confidence',r.confidence);
 insert into private.user_attribution(user_id,first_touch,last_touch,first_touch_at,last_touch_at) values(uid,touch_,touch_,at_,at_)
 on conflict(user_id) do update set
 first_touch=case when user_attribution.first_touch is null or (at_<=user_attribution.first_touch_at and coalesce((user_attribution.first_touch->>'confidence')::int,0)<r.confidence) then touch_ else user_attribution.first_touch end,
 first_touch_at=least(coalesce(user_attribution.first_touch_at,at_),at_),
 last_touch=case when user_attribution.last_touch is null or at_>user_attribution.last_touch_at or (at_=user_attribution.last_touch_at and coalesce((user_attribution.last_touch->>'confidence')::int,0)<r.confidence) then touch_ else user_attribution.last_touch end,
 last_touch_at=greatest(coalesce(user_attribution.last_touch_at,at_),at_);
 return private.source_of(uid);
end $$;
revoke all on function public.record_install_attribution(text,text,text,text,bigint,bigint) from public,anon;
grant execute on function public.record_install_attribution(text,text,text,text,bigint,bigint) to authenticated;

create or replace function public.record_install(p_install_id text,p_referrer_status text,p_raw_referrer text,p_install_secret text)
returns text language sql security definer set search_path='' as $$
 select public.record_install_attribution(p_install_id,p_referrer_status,p_raw_referrer,p_install_secret,null,null)
$$;

-- Trusted server route passes IP/UA itself. Browser clients cannot call this service-only RPC.
create function public.record_web_attribution(p_event text,p_event_id uuid,p_consent boolean,p_ip text,p_ua text,p_url text,p_fbc text default '',p_fbp text default '',p_referrer text default '')
returns boolean language plpgsql security definer set search_path='' as $$
declare rev bigint;p jsonb:=private.parse_referrer(p_referrer); inserted_ boolean;
begin
 if not p_consent or not private.meta_ready() or nullif(p_ip,'') is null then return false;end if;
 if p_event not in('PageView','Lead','PlanViewed') then raise exception 'event is not permitted';end if;
 if p_url!~'^https://puffle-iota[.]vercel[.]app(/[^?#]*)?$' then return false;end if;
 if (select count(*) from public.meta_events where client_ip=p_ip and action_source='website' and created_at>now()-interval '1 hour')>=120 then return false;end if;
 select revision into rev from public.meta_settings where id=1;
 insert into public.meta_events(event_name,event_id,action_source,advertising_consent,config_revision,fbc,fbp,client_ip,client_ua,source_url,custom_data)
 values(p_event,'web-'||p_event_id,'website',true,rev,nullif(left(p_fbc,600),''),nullif(left(p_fbp,200),''),left(p_ip,100),left(p_ua,400),left(p_url,500),
 case when p_event='Lead' then '{"content_name":"apk_download"}'::jsonb else '{}' end) on conflict(event_id) do nothing;
 inserted_:=found;
 if p_event='Lead' and inserted_ then
  insert into public.ad_clicks(event_id,fbc,fbp,ip,user_agent,utm_source,utm_medium,utm_campaign,utm_content,page_url)
  values(p_event_id,nullif(left(p_fbc,600),''),nullif(left(p_fbp,200),''),left(p_ip,100),left(p_ua,400),p->>'utm_source',p->>'utm_medium',p->>'utm_campaign',p->>'utm_content',left(p_url,500)) on conflict(event_id) do nothing;
 end if;
 return inserted_;
end $$;
revoke all on function public.record_web_attribution(text,uuid,boolean,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.record_web_attribution(text,uuid,boolean,text,text,text,text,text,text) to service_role;

-- Subscription is a conversion derived from the same verified order; never a client assertion.
create function private.enqueue_subscription_event() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.event_name='Purchase' and new.order_id is not null then
  insert into public.meta_events(event_name,event_id,user_id,order_id,value_inr,created_at,fbc,fbp,client_ip,client_ua,content_name,action_source,app_data,anon_id,custom_data,advertising_consent,config_revision)
  values('Subscribe','subscribe-'||new.order_id,new.user_id,new.order_id,new.value_inr,new.created_at,new.fbc,new.fbp,new.client_ip,new.client_ua,new.content_name,new.action_source,new.app_data,new.anon_id,new.custom_data,new.advertising_consent,new.config_revision)
  on conflict(event_id) do nothing;
 end if;
 return new;
end $$;
revoke all on function private.enqueue_subscription_event() from public,anon,authenticated;
create trigger meta_subscription_conversion after insert on public.meta_events for each row execute function private.enqueue_subscription_event();

create function public.admin_attribution_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501';end if;
 return jsonb_build_object(
 'installs_7d',(select count(*) from public.installs where created_at>now()-interval '7 days'),
 'matched_installs_7d',(select count(*) from public.installs where created_at>now()-interval '7 days' and attribution_source=private.meta_source() and confidence>=20),
 'recent',coalesce((select jsonb_agg(to_jsonb(r)) from(select i.install_id,i.referrer_status,i.attribution_source,i.confidence,i.utm_campaign,i.created_at,private.source_of(i.user_id) as audience from public.installs i order by i.created_at desc limit 30)r),'[]'::jsonb));
end $$;
revoke all on function public.admin_attribution_overview() from public,anon;
grant execute on function public.admin_attribution_overview() to authenticated;
