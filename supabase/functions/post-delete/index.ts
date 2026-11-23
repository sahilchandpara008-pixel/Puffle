import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.8";
const url=Deno.env.get("SUPABASE_URL")!;
const anon=Deno.env.get("SUPABASE_ANON_KEY")!;
const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"content-type":"application/json"}});
const admin=()=>createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
const userClient=(req:Request)=>createClient(url,anon,{global:{headers:{Authorization:req.headers.get("Authorization")??""}},auth:{persistSession:false,autoRefreshToken:false}});
async function user(req:Request){const sb=userClient(req);const {data,error}=await sb.auth.getUser();if(error||!data.user)throw new Error("unauthorized");return {sb,user:data.user};}
async function isOwner(uid:string){const {data}=await admin().from("admins").select("role").eq("user_id",uid).maybeSingle();return data?.role==="owner";}
async function adminRole(uid:string){const {data}=await admin().from("admins").select("role").eq("user_id",uid).maybeSingle();return data?.role??null;}

Deno.serve(async(req)=>{
 try{
  if(req.method!=="POST")return json({error:"method not allowed"},405);
  const {user:u}=await user(req); const b=await req.json(); const id=String(b?.post_id??""); const a=admin();
  const role=await adminRole(u.id); if(!role)return json({error:"forbidden"},403);
  if (typeof b?.channel_id === "string") {
    if (role !== "owner") return json({error:"Only the owner can delete a channel"},403);
    const channelId = b.channel_id;
    if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(channelId)) {
      return json({error:"Invalid channel"},400);
    }
    const { data: channel, error: lookup } = await a.from("channels").select("id,icon_url").eq("id", channelId).maybeSingle();
    if (lookup || !channel) return json({error:"Channel not found"},404);
    const files = new Set<string>();
    for (let offset = 0;; offset += 250) {
      const { data, error } = await a.from("post_items")
        .select("media_key,thumbnail_key,trailer_key,posts!inner(channel_id)")
        .eq("posts.channel_id", channelId).order("id").range(offset, offset + 249);
      if (error) return json({error:"Could not check channel files"},503);
      for (const item of data) {
        for (const key of [item.media_key, item.thumbnail_key, item.trailer_key]) {
          if (key && !key.includes("/bunny/")) files.add(key);
        }
      }
      if (data.length < 250) break;
    }
    const { error: deletion } = await a.from("channels").delete().eq("id", channelId);
    if (deletion) return json({error:"Could not delete the channel"},503);
    const keys = [...files];
    for (let offset = 0; offset < keys.length; offset += 100) {
      await a.storage.from("media").remove(keys.slice(offset, offset + 100));
    }
    if (channel.icon_url) await a.storage.from("channel-icons").remove([channel.icon_url]);
    return json({ok:true});
  }
  const {data:post,error:pe}=await a.from("posts").select("id,channel_id").eq("id",id).single(); if(pe||!post)return json({error:"not found"},404);
  if(role!=="owner"){const {data:access}=await a.from("admin_channel_access").select("channel_id").eq("user_id",u.id).eq("channel_id",post.channel_id).maybeSingle();if(!access)return json({error:"forbidden"},403);}
  const {data:items,error:itemError}=await a.from("post_items").select("media_key,thumbnail_key,trailer_key").eq("post_id",id);
  if(itemError)return json({error:"Could not check the post's videos"},503);
  if(role!=="owner" && (items??[]).some(i=>[i.media_key,i.trailer_key].some(k=>k?.includes("/bunny/"))))
    return json({error:"Only the owner can delete a Bunny Stream post"},403);
  const keys = [...new Set((items ?? []).flatMap(item =>
    [item.media_key, item.thumbnail_key, item.trailer_key]
      .filter((key): key is string => Boolean(key && !key.includes("/bunny/")))
  ))];
  const { error } = await a.from("posts").delete().eq("id", id);
  if (error) return json({error:error.message},400);
  if (keys.length) await a.storage.from("media").remove(keys);
  return json({ok:true});
 }catch(e){return json({error:e instanceof Error?e.message:"request failed"},401);}
});
