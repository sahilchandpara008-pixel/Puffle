-- Rollback-only Google measurement authorization, consent and paid-order tests.
do $outer$
declare u uuid:=gen_random_uuid();owner_ uuid:=gen_random_uuid();other_ uuid:=gen_random_uuid();plan_ uuid;order_ jsonb;result_ jsonb;v boolean;old_rev bigint;total_ int;failed_ int;names text;
begin
  -- Disposable payment fixture; the final test report rolls this back.
  update public.payment_settings set upi_id='fixture@upi',payee_name='Test Merchant',enabled=true,activation_mode='instant';
 create temp table checks(name text,ok boolean) on commit drop;
 create function pg_temp.ck(n text,v boolean) returns void language plpgsql security definer as $f$begin insert into pg_temp.checks values(n,coalesce(v,false));end$f$;
 create function pg_temp.imp(u uuid) returns void language plpgsql as $f$begin perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated','is_anonymous',false)::text,true);perform set_config('request.jwt.claim.sub',u::text,true);set local role authenticated;end$f$;
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,is_anonymous) select x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',x::text||'@example.test',now(),false from unnest(array[u,owner_,other_])x;
 insert into public.admins(user_id,role) values(owner_,'owner');
 insert into private.user_sources(user_id,source) values(u,'ads');
 update private.meta_cron set url='';
 update public.google_settings set app_enabled=true,firebase_app_id='1:123456789:android:abcdef0123456789',api_secret='fixture-secret',firebase_api_key='public-fixture';
 select revision into old_rev from public.google_settings where id=1;
 perform pg_temp.imp(u);select count(*)=0 into v from public.google_settings;reset role;
 perform pg_temp.ck('Google secrets owner only',v);
 result_:=public.google_public();perform pg_temp.ck('public settings never include server secret',not(result_?'api_secret') and not(result_?'ads_customer_id'));
 perform pg_temp.imp(u);v:=false;begin perform public.admin_google_report();exception when others then v:=true;end;reset role;perform pg_temp.ck('Google reports owner only',v);
 perform pg_temp.imp(u);v:=false;begin perform public.google_claim_batch();exception when others then v:=true;end;reset role;perform pg_temp.ck('app cannot claim conversion delivery',v);
 perform pg_temp.imp(u);v:=false;begin perform public.set_google_preferences(true,'not-a-firebase-instance','1:123456789:android:abcdef0123456789');exception when others then v:=true;end;reset role;perform pg_temp.ck('invalid native identity rejected',v);
 perform pg_temp.imp(u);perform public.set_google_preferences(true,'0123456789abcdef0123456789abcdef','1:123456789:android:abcdef0123456789',123456789);reset role;
 perform pg_temp.ck('explicit Google permission recorded',exists(select 1 from public.google_preferences where user_id=u and enabled));
 perform pg_temp.ck('Google choice does not opt into Meta',not exists(select 1 from public.measurement_preferences where user_id=u and advertising));
 perform pg_temp.imp(other_);select count(*)=0 into v from public.google_preferences where user_id=u;reset role;perform pg_temp.ck('Google preference belongs only to self',v);
 update public.app_mode set free_mode=false,plans_visible_for='everyone';
 update public.payment_settings set enabled=true,upi_id='fixture@upi',activation_mode='instant';select id into plan_ from public.plans where active order by position limit 1;
 perform pg_temp.imp(u);order_:=public.create_order(plan_);result_:=public.report_result((order_->>'order_id')::uuid,'txnId=GOOGLETEST123456&responseCode=00&Status=SUCCESS&txnRef='||(order_->>'reference'));reset role;
 perform pg_temp.ck('instant plan activation preserved',exists(select 1 from public.subscriptions where user_id=u and not revoked));
 perform pg_temp.ck('unverified success is not an ad conversion',not exists(select 1 from public.google_events where user_id=u));
 perform pg_temp.imp(owner_);perform public.admin_confirm_bank((order_->>'order_id')::uuid);reset role;
 perform pg_temp.ck('bank verified payment queues one Google purchase',(select count(*) from public.google_events where user_id=u and status='pending')=1);
 update public.payment_orders set bank_verified=true where id=(order_->>'order_id')::uuid;
 perform pg_temp.ck('repeated bank confirmation deduplicates',(select count(*) from public.google_events where user_id=u)=1);
 update public.google_settings set api_secret='rotated-fixture';perform pg_temp.ck('secret-only rotation preserves revision',(select revision=old_rev from public.google_settings where id=1));
 perform pg_temp.imp(u);perform public.set_google_preferences(false);reset role;
 perform pg_temp.ck('revocation suppresses unsent Google purchases',not exists(select 1 from public.google_events where user_id=u and status in('pending','processing')));
 perform pg_temp.ck('revocation deletes native instance context',not exists(select 1 from private.google_app_context where user_id=u));
 update public.google_settings set firebase_app_id='1:987654321:android:abcdef0123456789';perform pg_temp.ck('new Firebase destination increments revision',(select revision=old_rev+1 from public.google_settings where id=1));
 select count(*),count(*) filter(where not ok),string_agg(name,' | ') filter(where not ok) into total_,failed_,names from checks;
 raise exception 'RESULT total=% failed=% :: %',total_,failed_,coalesce(names,'none');
end $outer$;

