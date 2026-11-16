/** Server-only callers supply candidates; never import this into a client component. */
export type MetaCheck = {status:"accepted"|"timeout"|"rejected";message:string;trace?:string};
export const META_GRAPH_VERSION="v27.0";
export async function checkMetaCandidate(pixel:string,token:string,testCode:string,website:string,send:typeof fetch=fetch):Promise<MetaCheck>{
 if(!/^\d{5,20}$/.test(pixel)||!token)return {status:"rejected",message:"Enter a valid Dataset/Pixel ID and access token."};
 try{
  const response=await send(`https://graph.facebook.com/${META_GRAPH_VERSION}/${encodeURIComponent(pixel)}/events`,{
   method:"POST",headers:{Authorization:`Bearer ${token}`,"content-type":"application/json"},signal:AbortSignal.timeout(15000),
   body:JSON.stringify({data:[{event_name:"MetaConfigurationTest",event_id:"config-"+crypto.randomUUID(),event_time:Math.floor(Date.now()/1000),action_source:"website",event_source_url:website,
    user_data:{external_id:["db0f6a5477900867b01e2b6d9662bfaa4f04e0694c4ebc044ab97eb43f4919f6"]},custom_data:{configuration_test:true}}],...(testCode?{test_event_code:testCode}:{})})});
  const data=await response.json().catch(()=>({}));
  if(!response.ok||Number(data.events_received)!==1)return {status:"rejected",message:String(data?.error?.message??`Meta rejected the test (HTTP ${response.status}).`).replaceAll(token,"[redacted]").slice(0,700)};
  return {status:"accepted",message:"Meta accepted the configuration test event.",trace:data.fbtrace_id};
 }catch(error){
  const timeout=typeof error==="object"&&error!==null&&"name" in error&&["TimeoutError","AbortError"].includes(String(error.name));
  return {status:timeout?"timeout":"rejected",message:timeout?"Meta timed out. Candidates can be saved disabled; retry verification before switching on.":"Meta could not be reached. Existing settings were kept."};
 }
}
