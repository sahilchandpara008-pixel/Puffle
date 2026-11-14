import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import {createClient} from 'npm:@supabase/supabase-js@2.49.8';
import {purchasePayload} from './payload.ts';
const url=Deno.env.get('SUPABASE_URL')!,service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!;
const db=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
const reply=(x:unknown,status=200)=>new Response(JSON.stringify(x),{status,headers:{'content-type':'application/json'}});
async function authorized(req:Request){
 const key=req.headers.get('x-cron-key');if(key){const {data}=await db.rpc('meta_cron_ok',{p_key:key});if(data===true)return true;}
 const client=createClient(url,anon,{global:{headers:{Authorization:req.headers.get('Authorization')??''}},auth:{persistSession:false}});
 const {data}=await client.auth.getUser();if(!data.user)return false;const {data:role}=await client.rpc('admin_role');return role==='owner';
}
async function settings(){const {data,error}=await db.from('google_settings').select('app_enabled,firebase_app_id,api_secret,revision,test_mode').eq('id',1).single();if(error)throw error;return data;}
async function deliver(s:{firebase_app_id:string;api_secret:string},body:unknown,test:boolean){
 const endpoint=new URL('https://www.google-analytics.com/'+(test?'debug/':'')+'mp/collect');endpoint.searchParams.set('firebase_app_id',s.firebase_app_id);endpoint.searchParams.set('api_secret',s.api_secret);
 // Never include this URL in logs or errors: Measurement Protocol requires its secret in the query.
 const res=await fetch(endpoint,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(test?{...(body as object),validation_behavior:'ENFORCE_RECOMMENDATIONS'}:body),signal:AbortSignal.timeout(15000)});
 if(!res.ok)throw Error('Google endpoint HTTP '+res.status);
 if(test){const data=await res.json();if((data.validationMessages??[]).length)throw Error('Google payload validation failed: '+JSON.stringify(data.validationMessages).slice(0,300));}
}
Deno.serve(async req=>{
 try{
  if(req.method!=='POST')return reply({error:'Method not allowed'},405);if(!await authorized(req))return reply({error:'Forbidden'},403);
  const body=await req.json().catch(()=>({}));const s=await settings();
  if(!s.firebase_app_id||!s.api_secret)return reply({ok:false,message:'Import the Firebase Android configuration and save the Measurement Protocol API secret first.'});
  if(body.action==='validate'){
   await deliver(s,purchasePayload({order_id:crypto.randomUUID(),app_instance_id:'00000000000000000000000000000001',created_at:new Date().toISOString(),amount_paise:100,plan_name:'Setup validation'}),true);
   return reply({ok:true,structure_only:true,message:'Structure valid. Google does not validate credentials or destination IDs here. No live conversion sent.'});
  }
  if(!s.app_enabled)return reply({ok:false,message:'Android Google measurement is off.'});
  const {data:events,error}=await db.rpc('google_claim_batch',{p_limit:15});if(error)throw error;
  let submitted=0,validated=0,failed=0,suppressed=0;
  for(const e of events??[]){
   try{
    const current=await settings();if(!current.app_enabled||current.revision!==e.revision||current.firebase_app_id!==e.firebase_app_id)throw Error('SUPPRESS: destination changed');
    const [{data:pref},{data:order}]=await Promise.all([db.from('google_preferences').select('enabled,enabled_since').eq('user_id',e.user_id).single(),db.from('payment_orders').select('status,bank_verified,user_id,amount_paise,plan_name,activated_at').eq('id',e.order_id).single()]);
    if(!pref?.enabled||order?.status!=='paid'||!order.bank_verified||order.user_id!==e.user_id||new Date(order.activated_at)<new Date(pref.enabled_since))throw Error('SUPPRESS: permission withdrawn or order not verified');
    const payload=purchasePayload({order_id:e.order_id,app_instance_id:e.app_instance_id,session_id:e.session_id,created_at:order.activated_at,amount_paise:Number(order.amount_paise),plan_name:order.plan_name});
    await deliver(current,payload,current.test_mode);
    const {error:save}=await db.from('google_events').update({status:current.test_mode?'validated':'submitted',submitted_at:new Date().toISOString(),lease_until:null,last_error:null}).eq('id',e.id).eq('status','processing');if(save)throw save;
    if(current.test_mode)validated++;else submitted++;
   }catch(err){
    // Do not persist raw fetch exceptions: they can contain the secret-bearing URL.
    const message=err instanceof Error&&/^(SUPPRESS:|Google endpoint HTTP|Google payload validation|Purchase is outside|Invalid verified|Missing genuine)/.test(err.message)?err.message:'Google delivery failed; check setup and network';
    const stop=message.startsWith('SUPPRESS:');await db.from('google_events').update({status:stop?'suppressed':e.attempts>=8?'failed':'pending',lease_until:null,last_error:message.slice(0,400),next_attempt_at:new Date(Date.now()+Math.min(3600,30*2**e.attempts)*1000).toISOString()}).eq('id',e.id).eq('status','processing');
    if(stop)suppressed++;else failed++;
   }
  }return reply({ok:true,submitted,validated,failed,suppressed});
 }catch{return reply({error:'Google measurement check failed. Review settings and try again.'},500);}
});
