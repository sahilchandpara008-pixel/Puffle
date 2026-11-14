import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.8";

const url=Deno.env.get("SUPABASE_URL")!;
const anon=Deno.env.get("SUPABASE_ANON_KEY")!;
const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"content-type":"application/json"}});
const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
const graphVersion="v27.0";

function scoped(req:Request){
  return createClient(url,anon,{global:{headers:{Authorization:req.headers.get("Authorization")??""}},auth:{persistSession:false,autoRefreshToken:false}});
}
async function owner(req:Request){
  const sb=scoped(req); const {data}=await sb.auth.getUser(); if(!data.user)return false;
  const {data:r}=await sb.from("admins").select("role").eq("user_id",data.user.id).maybeSingle();
  return r?.role==="owner";
}
async function cronOk(req:Request){
  const key=req.headers.get("x-cron-key")??""; if(!key)return false;
  const {data}=await admin.rpc("meta_cron_ok",{p_key:key}); return data===true;
}
async function sha256(s:string){
  const b=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,"0")).join("");
}
async function settings(){
  const {data,error}=await admin.from("meta_settings").select("pixel_id,capi_token,test_event_code,enabled").eq("id",1).single();
  if(error)throw error; return data;
}
async function metaFetch(pixel:string,token:string,body:unknown){
  const r=await fetch(`https://graph.facebook.com/${graphVersion}/${encodeURIComponent(pixel)}/events?access_token=${encodeURIComponent(token)}`,{
    method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(body),
  });
  const j=await r.json().catch(()=>({}));
  if(!r.ok)throw new Error(String(j?.error?.message??`Meta HTTP ${r.status}`));
  return j;
}
async function flush(limit=50){
  const s=await settings(); if(!s.enabled||!s.pixel_id||!s.capi_token)return {skipped:true,sent:0,failed:0,pending:0};
  const {data:rows,error}=await admin.from("meta_events").select("*").eq("status","pending").lt("attempts",5).order("created_at").limit(limit);
  if(error)throw error; let sent=0,failed=0;
  for(const e of rows??[]){
    try{
      const user_data:any={};
      if(e.client_ip)user_data.client_ip_address=e.client_ip;
      if(e.client_ua)user_data.client_user_agent=e.client_ua;
      if(e.fbc)user_data.fbc=e.fbc;
      if(e.fbp)user_data.fbp=e.fbp;
      if(e.user_id)user_data.external_id=[await sha256(String(e.user_id))];
      const event:any={
        event_name:e.event_name,
        event_time:Math.floor(new Date(e.created_at).getTime()/1000),
        event_id:e.event_id,
        action_source:e.event_name==="Lead"?"website":"app",
        user_data,
      };
      if(e.source_url)event.event_source_url=e.source_url;
      if(e.value_inr!=null)event.custom_data={currency:"INR",value:Number(e.value_inr),...(e.content_name?{content_name:e.content_name}:{})};
      await metaFetch(s.pixel_id,s.capi_token,{data:[event]});
      await admin.from("meta_events").update({status:"sent",sent_at:new Date().toISOString(),attempts:(e.attempts??0)+1,last_error:null}).eq("id",e.id);
      sent++;
    }catch(err){
      const attempts=(e.attempts??0)+1; const terminal=attempts>=5;
      await admin.from("meta_events").update({status:terminal?"failed":"pending",attempts,last_error:String(err instanceof Error?err.message:err).slice(0,1000)}).eq("id",e.id);
      failed++;
    }
  }
  const {count}=await admin.from("meta_events").select("id",{count:"exact",head:true}).eq("status","pending").lt("attempts",5);
  return {sent,failed,pending:count??0};
}

Deno.serve(async(req)=>{
  try{
    if(req.method!=="POST")return json({error:"method not allowed"},405);
    const automatic=await cronOk(req);
    if(!automatic && !await owner(req))return json({error:"forbidden"},403);
    const body=await req.json().catch(()=>({})); const action=String(body?.action??"flush");
    const s=await settings();
    if(action==="verify"){
      if(!s.pixel_id||!s.capi_token)return json({ok:false,message:"Pixel ID and CAPI token are required"});
      const r=await fetch(`https://graph.facebook.com/${graphVersion}/${encodeURIComponent(s.pixel_id)}?fields=name&access_token=${encodeURIComponent(s.capi_token)}`);
      const j=await r.json().catch(()=>({}));
      if(!r.ok)return json({ok:false,message:String(j?.error?.message??"Meta rejected the credentials")});
      return json({ok:true,name:j?.name??s.pixel_id});
    }
    if(action==="test"){
      if(!s.enabled||!s.pixel_id||!s.capi_token)return json({ok:false,message:"Enable Meta and save a Pixel ID and token first"});
      if(!s.test_event_code)return json({ok:false,message:"Add a Meta Test Event Code before sending a test"});
      const ev={event_name:"Purchase",event_time:Math.floor(Date.now()/1000),event_id:`puffle-test-${crypto.randomUUID()}`,action_source:"website",event_source_url:"https://puffle-iota.vercel.app",user_data:{client_user_agent:"Puffle Admin Test"},custom_data:{currency:"INR",value:1}};
      const m=await metaFetch(s.pixel_id,s.capi_token,{data:[ev],test_event_code:s.test_event_code});
      return json({ok:true,meta:m});
    }
    const r=await flush(); return json(r);
  }catch(e){return json({error:e instanceof Error?e.message:"meta send failed"},500);}
});