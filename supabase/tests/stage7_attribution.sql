-- Fixtures and cron changes are transaction-local. Execute inside BEGIN/ROLLBACK.
create temp table attribution_checks(name text,ok boolean) on commit drop;
do $$
declare u uuid:=gen_random_uuid(); other_ uuid:=gen_random_uuid(); id_ text:=gen_random_uuid()::text; secret_ text:=gen_random_uuid()::text; event_ uuid:=gen_random_uuid(); v boolean; result_ text;
begin
 insert into attribution_checks values
 ('Google Play organic classified',private.classify_referrer('utm_source=google-play&utm_medium=organic','play_ok')='organic'),
 ('Meta classified',private.classify_referrer('utm_source=meta&utm_medium=paid_social','play_ok')=private.meta_source()),
 ('non-Play direct classified',private.classify_referrer('','direct')='direct'),
 ('unavailable Play is unknown',private.classify_referrer('','not_available')='unknown'),
 ('other source classified',private.classify_referrer('utm_source=newsletter','play_ok')='other'),
 ('encrypted payload not guessed',private.classify_referrer('encrypted=opaque','play_ok')='unknown'),
 ('encoded values parsed',private.parse_referrer('utm_source=meta&utm_campaign=New%20Campaign&utm_content=a%26b')->>'utm_content'='a&b'),
 ('whole referrer decoded once',private.parse_referrer('utm_source%3Dmeta%26utm_campaign%3Dhello')->>'utm_source'='meta'),
 ('plus decoded',private.parse_referrer('utm_campaign=hello+world')->>'utm_campaign'='hello world'),
 ('malformed escape safe',private.parse_referrer('utm_campaign=%ZZ')->>'utm_campaign'='%ZZ'),
 ('first duplicate wins',private.parse_referrer('utm_source=google-play&utm_source=meta')->>'utm_source'='google-play');
 insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,is_anonymous)
 select x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',x::text||'@example.test',now(),false from unnest(array[u,other_])x;
 update private.meta_cron set url='';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',u::text,true);
 result_:=public.record_install_attribution(id_,'not_available','',secret_);
 insert into attribution_checks values('unknown safe audience',result_='organic');
 perform public.record_install_attribution(id_,'play_ok','utm_source=meta&utm_medium=paid_social&utm_campaign=one',secret_);
 insert into attribution_checks values('higher-confidence correction',(select confidence=30 and utm_campaign='one' from public.installs where install_id=id_));
 insert into attribution_checks values('existing access is preserved',public.source_of()='organic');
 perform public.record_install_attribution(id_,'not_available','',secret_);
 insert into attribution_checks values('lower confidence cannot erase campaign',(select confidence=30 and utm_campaign='one' from public.installs where install_id=id_));
 perform public.record_install_attribution(id_,'play_ok','utm_source=meta&utm_campaign=two',secret_);
 insert into attribution_checks values('equal confidence preserves first evidence',(select utm_campaign='one' from public.installs where install_id=id_));
 insert into attribution_checks values('first and last touches linked',(select first_touch->>'campaign'='one' and last_touch->>'campaign'='one' from private.user_attribution where user_id=u));
 v:=false;begin perform public.record_install_attribution(id_,'play_ok','utm_source=meta','wrong-secret-long-enough');exception when insufficient_privilege then v:=true;end;
 insert into attribution_checks values('install ownership secret checked',v);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',other_,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',other_::text,true);
 result_:=public.record_install_attribution(gen_random_uuid()::text,'play_ok','utm_source=meta&utm_medium=paid_social',gen_random_uuid()::text);
 insert into attribution_checks values('new Meta acquisition has ads source',result_='ads');
 update public.meta_settings set enabled=true,pixel_id='123456789012',capi_token='fixture-only';
 v:=public.record_web_attribution('Lead',event_,false,'192.0.2.1','fixture','https://puffle-iota.vercel.app/get');
 insert into attribution_checks values('no consent no click',not v and not exists(select 1 from public.ad_clicks where event_id=event_));
 v:=public.record_web_attribution('Lead',event_,true,'192.0.2.1','fixture','https://puffle-iota.vercel.app/get','','','utm_source=meta&utm_campaign=test');
 insert into attribution_checks values('Lead and click atomically linked',v and exists(select 1 from public.ad_clicks where event_id=event_ and utm_campaign='test') and exists(select 1 from public.meta_events where event_id='web-'||event_));
 perform public.record_web_attribution('Lead',event_,true,'192.0.2.1','fixture','https://puffle-iota.vercel.app/get');
 insert into attribution_checks values('Lead retry deduplicated',(select count(*)=1 from public.ad_clicks where event_id=event_));
 v:=public.record_web_attribution('Lead',gen_random_uuid(),true,'192.0.2.1','fixture','https://attacker.test/');
 insert into attribution_checks values('external page rejected',not v);
 insert into attribution_checks values('anonymous cannot call trusted ingest',not has_function_privilege('anon','public.record_web_attribution(text,uuid,boolean,text,text,text,text,text,text)','EXECUTE'));
 insert into attribution_checks values('authenticated cannot forge trusted ingest',not has_function_privilege('authenticated','public.record_web_attribution(text,uuid,boolean,text,text,text,text,text,text)','EXECUTE'));
 insert into attribution_checks values('private parser unavailable to clients',not has_function_privilege('authenticated','private.parse_referrer(text)','EXECUTE'));
end $$;
select count(*) as total,count(*) filter(where not coalesce(ok,false)) as failed,jsonb_agg(name) filter(where not coalesce(ok,false)) as failures from attribution_checks;
