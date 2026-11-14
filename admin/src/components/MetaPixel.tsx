"use client";
import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";
import {hasAdvertisingConsent} from "./PrivacyChoices";
type Fbq=((...args:unknown[])=>void)&{queue?:unknown[];loaded?:boolean;version?:string;push?:unknown;callMethod?:(...args:unknown[])=>void};
declare global {interface Window {fbq?:Fbq;_fbq?:Fbq;__pufflePixel?:{at:number;id:string|null;pending?:Promise<string|null>};}}
const cookie=(name:string)=>{try{return decodeURIComponent(document.cookie.match(new RegExp("(?:^|; )"+name+"=([^;]*)"))?.[1]??"");}catch{return "";}};
export function fromAd(){const q=new URLSearchParams(location.search);if(q.get("fbclid")||q.get("gclid")||q.get("gbraid")||q.get("wbraid")||(/^(meta|facebook|instagram|ig|fb)$/i.test(q.get("utm_source")??"")||(/^(google|google_ads)$/i.test(q.get("utm_source")??"")&&/^(cpc|ppc|paid|paid_search|display|video)$/i.test(q.get("utm_medium")??"")))){try{sessionStorage.setItem("puffle_download_variant","ads");}catch{}return true;}try{return sessionStorage.getItem("puffle_download_variant")==="ads";}catch{return false;}}
export async function loadPixel():Promise<string|null>{
 if(!hasAdvertisingConsent())return null;
 const cache=window.__pufflePixel;
 if(cache&&Date.now()-cache.at<60000)return cache.pending??cache.id;
 const pending=(async()=>{
  try{
   const {data}=await supabaseBrowser().rpc("meta_public");
   const id=String((data as {pixel_id?:string}|null)?.pixel_id??"");
   if(!hasAdvertisingConsent()||!/^\d{5,20}$/.test(id)){window.fbq?.("consent","revoke");window.__pufflePixel={id:null,at:Date.now()};return null;}
   if(!window.fbq){
    const n:Fbq=function(...args:unknown[]){if(n.callMethod)n.callMethod(...args);else n.queue!.push(args);} as Fbq;
    n.push=n;n.loaded=true;n.version="2.0";n.queue=[];window.fbq=n;window._fbq=n;
    const script=document.createElement("script");script.async=true;script.src="https://connect.facebook.net/en_US/fbevents.js";document.head.appendChild(script);
   }
   window.fbq!("consent","grant");
   window.fbq!("set","autoConfig",false,id);if(cache?.id!==id)window.fbq!("init",id);
   window.__pufflePixel={id,at:Date.now()};return id;
  }catch{window.__pufflePixel={id:null,at:Date.now()};return null;}
 })();
 window.__pufflePixel={at:Date.now(),id:null,pending};return pending;
}
export async function trackWebEvent(event:"PageView"|"Lead"|"PlanViewed",eventId=crypto.randomUUID()){
 if(!hasAdvertisingConsent())return;
 const id=await loadPixel();if(!id||!hasAdvertisingConsent())return;
 window.fbq!(event==="PlanViewed"?"trackSingleCustom":"trackSingle",id,event,event==="Lead"?{content_name:"apk_download"}:{},{eventID:"web-"+eventId});
 const q=new URLSearchParams(location.search);
 let click=q.get("fbclid")??"";
 try{if(click){sessionStorage.setItem("orbix_fbclid",click);sessionStorage.setItem("orbix_ad","1");}else click=sessionStorage.getItem("orbix_fbclid")??"";}catch{}
 await fetch(process.env.NEXT_PUBLIC_SUPABASE_URL+"/rest/v1/rpc/record_web_measurement",{method:"POST",keepalive:true,headers:{"apikey":process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,"content-type":"application/json"},body:JSON.stringify({p_event:event,p_event_id:eventId,p_consent:true,p_fbclid:click,p_fbc:cookie("_fbc"),p_fbp:cookie("_fbp"),p_url:location.origin+location.pathname})}).then(()=>{},()=>{});
}
export default function MetaPixel(){
 const path=usePathname();
 useEffect(()=>{
  let live=true;const send=()=>{if(live)void trackWebEvent("PageView");};
  send();const changed=()=>{window.__pufflePixel=undefined;send();};
  window.addEventListener("puffle-privacy-change",changed);
  const refresh=()=>{window.__pufflePixel=undefined;void loadPixel();};
  const timer=setInterval(refresh,60000);
  return()=>{live=false;clearInterval(timer);window.removeEventListener("puffle-privacy-change",changed);};
 },[path]);
 return null;
}

