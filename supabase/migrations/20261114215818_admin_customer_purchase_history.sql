-- Purchase history is for the owner admin only. No repeat-buyer labels enter advertising payloads.
create or replace function public.admin_customer_purchases(p_user uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result_ jsonb;
begin
 if not public.is_owner() then raise exception 'forbidden' using errcode='42501';end if;
 with paid as(select id,plan_code,plan_name,amount_paise,activated_at,bank_verified,reference,
 lag(plan_code) over(order by activated_at,id) as previous_code,
 lag(plan_name) over(order by activated_at,id) as previous_plan,
 lag(amount_paise) over(order by activated_at,id) as previous_amount
 from public.payment_orders where user_id=p_user and status='paid'),
 history as(select id,plan_code,plan_name,amount_paise/100.0 as amount_inr,activated_at,bank_verified,reference,previous_plan,previous_amount/100.0 as previous_amount_inr,
 case when previous_code is null then 'First purchase' when plan_code=previous_code then 'Same plan' when amount_paise>previous_amount then 'Higher-priced plan' when amount_paise<previous_amount then 'Lower-priced plan' else 'Different plan, same price' end as change
 from paid order by activated_at desc,id desc limit 200)
 select jsonb_build_object('user_id',p_user,'email',(select email from auth.users where id=p_user),'paid_orders',(select count(*) from paid),
 'spent',coalesce((select sum(amount_paise)/100.0 from paid),0),'history',coalesce((select jsonb_agg(to_jsonb(h)) from history h),'[]'::jsonb)) into result_;
 return result_;
end $$;
revoke all on function public.admin_customer_purchases(uuid) from public,anon;grant execute on function public.admin_customer_purchases(uuid) to authenticated;
