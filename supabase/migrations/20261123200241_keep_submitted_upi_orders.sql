create or replace function private.cancel_stale_orders() returns void
language sql security definer set search_path = '' as $$
  update public.payment_orders set status = 'cancelled'
  where status = 'pending' and not success_reported and created_at < now() - interval '72 hours';
$$;

create or replace function public.report_result(p_order uuid, p_raw text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  orders public.payment_orders;
  raw text := coalesce(p_raw, '');
  result_status text;
  transaction_id text;
  result_reference text;
  approval_reference text;
  activation text;
  recent integer;
  inserted integer;
begin
  select * into orders from public.payment_orders where id = p_order and user_id = uid for update;
  if not found then raise exception 'order not found'; end if;
  if orders.status not in ('pending', 'submitted') then return private.order_json(orders.id); end if;

  result_status := upper(coalesce(nullif(private.upi_param(raw, 'Status'), ''), private.upi_param(raw, 'txnStatus'), ''));
  approval_reference := nullif(private.upi_param(raw, 'ApprovalRefNo'), '');
  transaction_id := coalesce(nullif(private.upi_param(raw, 'txnId'), ''), approval_reference);
  result_reference := private.upi_param(raw, 'txnRef');

  -- A later cancelled attempt cannot overwrite evidence already recorded for this order.
  if (orders.status = 'submitted' or orders.success_reported) and result_status <> 'SUCCESS' then
    return private.order_json(orders.id);
  end if;
  update public.payment_orders set raw_result = left(raw, 4000), reported_at = now() where id = orders.id;
  if result_status in ('FAILURE', 'FAILED') then
    update public.payment_orders set status = 'failed' where id = orders.id;
  elsif result_status = 'SUBMITTED' then
    update public.payment_orders set status = 'submitted' where id = orders.id;
  elsif result_status = 'SUCCESS' then
    update public.payment_orders set success_reported = true where id = orders.id;
    if result_reference ~ '^[0-9]{12}$' and lower(result_reference) <> lower(orders.reference) then
      -- Bank references from a phone are useful for reconciliation but do not verify settlement.
      update public.payment_orders set utr = result_reference, status = 'review',
        txn_id = left(transaction_id, 100), approval_ref = left(approval_reference, 100) where id = orders.id;
    elsif lower(coalesce(result_reference, '')) = lower(orders.reference)
        and transaction_id ~ '^[A-Za-z0-9]{6,40}$'
        and orders.created_at > now() - interval '2 hours' then
      insert into private.used_payment_utrs(txn_id, order_id) values (upper(transaction_id), orders.id)
      on conflict (txn_id) do nothing;
      get diagnostics inserted = row_count;
      if inserted = 1 then
        update public.payment_orders set txn_id = transaction_id, approval_ref = approval_reference where id = orders.id;
        select activation_mode into activation from public.payment_settings where id = 1;
        select count(*) into recent from public.payment_orders
        where user_id = uid and status = 'paid' and activation_kind = 'auto' and activated_at > now() - interval '24 hours';
        if activation = 'manual' or recent >= 3 then
          update public.payment_orders set status = 'review' where id = orders.id;
        else
          perform private.activate_order(orders.id, 'auto');
        end if;
      end if;
    end if;
  end if;
  return private.order_json(orders.id);
end;
$$;

create function public.submit_order_utr(p_order uuid, p_utr text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare orders public.payment_orders;
begin
  if p_utr is null or p_utr !~ '^[0-9]{12}$' then
    raise exception 'Enter a 12-digit bank reference' using errcode = '22023';
  end if;
  select * into orders from public.payment_orders where id = p_order and user_id = auth.uid() for update;
  if not found then raise exception 'Order not found' using errcode = '42501'; end if;
  if orders.status = 'paid' or orders.bank_verified then return private.order_json(orders.id); end if;
  if orders.created_at < now() - interval '72 hours'
    or orders.status not in ('pending','submitted','review','failed','cancelled') then
    raise exception 'Contact support for this order' using errcode = '22023';
  end if;
  update public.payment_orders set utr = p_utr, status = 'review', reported_at = now() where id = orders.id;
  return private.order_json(orders.id);
end;
$$;
revoke all on function public.submit_order_utr(uuid,text) from public, anon;
grant execute on function public.submit_order_utr(uuid,text) to authenticated;
