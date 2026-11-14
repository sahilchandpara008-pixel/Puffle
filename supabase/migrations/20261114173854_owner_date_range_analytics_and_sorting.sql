
create or replace function public.admin_users_filtered(p_search text default null,p_source text default null,p_plan text default null,p_guest boolean default null,p_access text default null,p_from date default null,p_to date default null,p_customer text default null,p_sort text default 'newest',p_limit int default 50,p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result_ jsonb;
begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501'; end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Start date must not follow end date'; end if;
 with spending as (
  select user_id,count(*) as paid_orders,sum(amount_paise)/100.0 as spent,
  coalesce(sum(amount_paise) filter(where bank_verified),0)/100.0 as verified_spent
  from public.payment_orders where status='paid' group by user_id),
 activity as(select user_id,max(occurred_at) as last_seen,count(distinct session_id) as sessions from private.app_activity group by user_id),
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
end $$;
revoke all on function public.admin_users_filtered(text,text,text,boolean,text,date,date,text,text,int,int) from public,anon;
grant execute on function public.admin_users_filtered(text,text,text,boolean,text,date,date,text,text,int,int) to authenticated;

create or replace function public.admin_payments_filtered(p_status text default null,p_plan text default null,p_from date default null,p_to date default null,p_search text default null,p_sort text default 'newest',p_verify text default null,p_source text default null,p_customer text default null,p_date_basis text default 'created',p_limit int default 100,p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Kolkata')::date; result_ jsonb;
begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501'; end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Start date must not follow end date'; end if;
 with paid as(select user_id,count(*) as paid_orders from public.payment_orders where status='paid' group by user_id),
 base as(
 select o.id,o.created_at,o.updated_at,coalesce(u.email,o.email_at_purchase) as email,o.user_id,
 coalesce(u.is_anonymous,false) as guest,o.plan_code,o.plan_name,o.amount_paise/100.0 as amount_inr,o.reference,o.utr,o.txn_id,o.upi_id_used,
 o.status,o.activation_kind,o.activated_at,o.bank_verified,o.bank_verified_at,o.admin_note,o.raw_result,
 coalesce(us.source,'organic') as source,coalesce(pd.paid_orders,0) as paid_orders,
 case when p_date_basis='activated' then o.activated_at else o.created_at end as date_basis
 from public.payment_orders o left join auth.users u on u.id=o.user_id left join private.user_sources us on us.user_id=o.user_id left join paid pd on pd.user_id=o.user_id
 where(nullif(p_status,'') is null or o.status=p_status)
 and(nullif(p_plan,'') is null or o.plan_code=p_plan)
 and(nullif(p_source,'') is null or coalesce(us.source,'organic')=p_source)
 and(nullif(p_search,'') is null or o.reference ilike '%'||left(p_search,200)||'%' or o.utr ilike '%'||left(p_search,200)||'%' or o.txn_id ilike '%'||left(p_search,200)||'%' or coalesce(u.email,o.email_at_purchase) ilike '%'||left(p_search,200)||'%' or o.user_id::text=p_search)
 and(nullif(p_verify,'') is null or(p_verify='verified' and o.bank_verified) or(p_verify='unverified' and not o.bank_verified)
  or(p_verify='all' and(o.status='review' or(o.status='paid' and not o.bank_verified)))
  or(p_verify='today' and(o.status='review' or(o.status='paid' and not o.bank_verified and(o.activated_at at time zone 'Asia/Kolkata')::date=today))))),
 filtered as(select * from base where
 (p_from is null or date_basis>=p_from::timestamp at time zone 'Asia/Kolkata')
 and(p_to is null or date_basis<(p_to+1)::timestamp at time zone 'Asia/Kolkata')
 and(nullif(p_customer,'') is null or(p_customer='repeat' and paid_orders>=2) or(p_customer='first' and paid_orders=1))),
 sorted as(select * from filtered order by
  case when p_sort='oldest' then created_at end asc nulls last,
  case when p_sort='highest' then amount_inr end desc nulls last,
  case when p_sort='lowest' then amount_inr end asc nulls last,
  case when p_sort='activated' then activated_at end desc nulls last,
  created_at desc,id limit least(greatest(p_limit,1),200) offset greatest(p_offset,0))
 select jsonb_build_object('total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(s)) from sorted s),'[]'::jsonb)) into result_;
 return result_;
end $$;
revoke all on function public.admin_payments_filtered(text,text,date,date,text,text,text,text,text,text,int,int) from public,anon;
grant execute on function public.admin_payments_filtered(text,text,date,date,text,text,text,text,text,text,int,int) to authenticated;

create or replace function public.admin_analytics(p_from date default null,p_to date default null,p_source text default null,p_plan text default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result_ jsonb; lo timestamptz:=coalesce(p_from::timestamp at time zone 'Asia/Kolkata','-infinity'::timestamptz); hi timestamptz:=coalesce((p_to+1)::timestamp at time zone 'Asia/Kolkata','infinity'::timestamptz);
begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501'; end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Start date must not follow end date'; end if;
 with users_ as(
 select p.id,p.created_at,p.is_guest,coalesce(s.source,'organic') as source from public.profiles p left join private.user_sources s on s.user_id=p.id
 where(nullif(p_source,'') is null or coalesce(s.source,'organic')=p_source)),
 orders_ as(
 select o.*,u.source from public.payment_orders o join users_ u on u.id=o.user_id
 where o.status='paid' and(nullif(p_plan,'') is null or o.plan_code=p_plan)),
 selected_orders as(select * from orders_ where activated_at>=lo and activated_at<hi),
 totals as(select user_id,count(*) as paid_orders from public.payment_orders where status='paid' group by user_id),
 activity as(
 select a.* from private.app_activity a join users_ u on u.id=a.user_id join public.measurement_preferences pref on pref.user_id=a.user_id and pref.analytics
 where a.occurred_at>=lo and a.occurred_at<hi),
 daily as(
 select (activated_at at time zone 'Asia/Kolkata')::date as day,count(*) as orders,sum(amount_paise)/100.0 as activated_revenue,
 coalesce(sum(amount_paise) filter(where bank_verified),0)/100.0 as verified_revenue from selected_orders group by 1 order by 1),
 plans_ as(select plan_code,plan_name,count(*) as orders,sum(amount_paise)/100.0 as revenue,
 coalesce(sum(amount_paise) filter(where bank_verified),0)/100.0 as verified_revenue from selected_orders group by 1,2 order by verified_revenue desc,orders desc),
 repeat_ as(select o.user_id,coalesce(u.email,'Guest') as email,count(*) as orders_in_range,max(t.paid_orders) as lifetime_paid_orders,sum(o.amount_paise)/100.0 as spent
 from selected_orders o join totals t on t.user_id=o.user_id left join auth.users u on u.id=o.user_id
 where t.paid_orders>=2 group by o.user_id,u.email order by spent desc limit 100),
 sources_ as(select u.source,count(*) as new_users from users_ u where created_at>=lo and created_at<hi group by u.source),
 events_ as(select event_name,count(*) as events,count(distinct user_id) as users from activity group by event_name order by events desc)
 select jsonb_build_object(
 'from',p_from,'to',p_to,'timezone','Asia/Kolkata',
 'activated_revenue',coalesce((select sum(amount_paise)/100.0 from selected_orders),0),
 'verified_revenue',coalesce((select sum(amount_paise)/100.0 from selected_orders where bank_verified),0),
 'unverified_revenue',coalesce((select sum(amount_paise)/100.0 from selected_orders where not bank_verified),0),
 'paid_orders',(select count(*) from selected_orders),
 'paying_users',(select count(distinct user_id) from selected_orders),
 'repeat_buyers',(select count(distinct o.user_id) from selected_orders o join totals t on t.user_id=o.user_id where t.paid_orders>=2),
 'new_users',(select count(*) from users_ where created_at>=lo and created_at<hi),
 'new_registrations',(select count(*) from users_ u join auth.users a on a.id=u.id where a.email_confirmed_at>=lo and a.email_confirmed_at<hi and not u.is_guest),
 'active_users',(select count(distinct user_id) from activity),
 'returning_users',(select count(distinct a.user_id) from activity a where exists(select 1 from private.app_activity earlier where earlier.user_id=a.user_id and earlier.occurred_at<lo)),
 'sessions',(select count(distinct(user_id,session_id)) from activity),
 'daily',coalesce((select jsonb_agg(to_jsonb(d)) from daily d),'[]'::jsonb),
 'plans',coalesce((select jsonb_agg(to_jsonb(p)) from plans_ p),'[]'::jsonb),
 'repeat_customers',coalesce((select jsonb_agg(to_jsonb(r)) from repeat_ r),'[]'::jsonb),
 'sources',coalesce((select jsonb_agg(to_jsonb(s)) from sources_ s),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(e)) from events_ e),'[]'::jsonb)
 ) into result_;
 return result_;
end $$;
revoke all on function public.admin_analytics(date,date,text,text) from public,anon;
grant execute on function public.admin_analytics(date,date,text,text) to authenticated;

