import {NextRequest,NextResponse} from "next/server";
import {createClient} from "@supabase/supabase-js";
export const runtime="nodejs";
export async function POST(req:NextRequest){
 const origin=req.headers.get("origin");
 if(origin!==req.nextUrl.origin)return NextResponse.json({ok:false},{status:403});
 if(Number(req.headers.get("content-length")??0)>6000)return NextResponse.json({ok:false},{status:413});
 const text=await req.text();if(text.length>6000)return NextResponse.json({ok:false},{status:413});
 let b;try{b=JSON.parse(text);}catch{return NextResponse.json({ok:false},{status:400});}
 if(b.consent!==true||!["PageView","Lead","PlanViewed"].includes(b.event)||!/^[0-9a-f-]{36}$/i.test(b.event_id??""))return NextResponse.json({ok:false},{status:400});
 const key=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!key)return NextResponse.json({ok:false},{status:503});
 const sb=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,key,{auth:{persistSession:false,autoRefreshToken:false}});
 // Vercel overwrites this header at its trusted edge. Never accept an IP from request JSON.
 const ip=req.headers.get("x-vercel-forwarded-for")?.split(",")[0]?.trim();
 if(!ip)return NextResponse.json({ok:false},{status:503});
 const path=typeof b.path==="string"&&b.path.startsWith("/")&&!b.path.startsWith("//")?b.path.split(/[?#]/)[0]:"/";
 const {data,error}=await sb.rpc("record_web_attribution",{p_event:b.event,p_event_id:b.event_id,p_consent:true,p_ip:ip,p_ua:req.headers.get("user-agent")??"",p_url:req.nextUrl.origin+path,
  p_fbc:String(b.fbc??"").slice(0,600),p_fbp:String(b.fbp??"").slice(0,200),p_referrer:String(b.referrer??"").slice(0,2048)});
 return NextResponse.json({ok:!error&&data===true},{status:error?500:200});
}
