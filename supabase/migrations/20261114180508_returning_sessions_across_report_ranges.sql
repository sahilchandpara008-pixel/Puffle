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
 'returning_users',(select count(distinct a.user_id) from activity a where exists(select 1 from private.app_activity earlier where earlier.user_id=a.user_id and earlier.session_id<>a.session_id and earlier.occurred_at<a.occurred_at)),
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

