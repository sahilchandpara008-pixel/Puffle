"use client";
import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";
import {hasAdvertisingConsent} from "./PrivacyChoices";
import {isPaidDownloadQuery} from "@/lib/download-attribution";
type Fbq=((...args:unknown[])=>void)&{queue?:unknown[];loaded?:boolean;version?:string;push?:unknown;callMethod?:(...args:unknown[])=>void};
declare global {interface Window {fbq?:Fbq;_fbq?:Fbq;__pufflePixelIds?:Set<string>;__pufflePixel?:{at:number;id:string|null;pending?:Promise<string|null>};}}
const cookie=(name:string)=>{try{return decodeURIComponent(document.cookie.match(new RegExp("(?:^|; )"+name+"=([^;]*)"))?.[1]??"");}catch{return "";}};
export function fromAd(){
 const q=new URLSearchParams(location.search);
 if(isPaidDownloadQuery(q)){
  try{sessionStorage.setItem("puffle_download_variant","ads");}catch{}return true;
 }
 try{return sessionStorage.getItem("puffle_download_variant")==="ads";}catch{return false;}
}
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
   window.fbq!("set","autoConfig",false,id);window.__pufflePixelIds??=new Set<string>();if(!window.__pufflePixelIds.has(id)){window.fbq!("init",id);window.__pufflePixelIds.add(id);}
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
 try{if(click){sessionStorage.setItem("puffle_fbclid",click);sessionStorage.setItem("puffle_ad","1");}else click=sessionStorage.getItem("puffle_fbclid")??"";}catch{}
 let fbc=cookie("_fbc");
 if(!fbc&&click)fbc="fb.1."+Date.now()+"."+click;
 const utm=new URLSearchParams();for(const key of ["utm_source","utm_medium","utm_campaign","utm_content","utm_term"]){const v=q.get(key);if(v)utm.set(key,v.slice(0,200));}
 try{if(utm.size)sessionStorage.setItem("puffle_utm",utm.toString());}catch{}
 let referrer=utm.toString();try{referrer||=sessionStorage.getItem("puffle_utm")??"";}catch{}
 await fetch("/api/meta-event",{method:"POST",keepalive:true,headers:{"content-type":"application/json"},body:JSON.stringify({event,event_id:eventId,consent:true,fbc,fbp:cookie("_fbp"),path:location.pathname,referrer})}).then(()=>{},()=>{});
}
export default function MetaPixel(){
 const path=usePathname();
 useEffect(()=>{
  let live=true;const send=()=>{if(live)void trackWebEvent("PageView");};
  send();const changed=()=>{if(window.__pufflePixel)window.__pufflePixel.at=0;send();};
  window.addEventListener("puffle-privacy-change",changed);
  const refresh=()=>{if(window.__pufflePixel)window.__pufflePixel.at=0;void loadPixel();};
  const timer=setInterval(refresh,60000);
  return()=>{live=false;clearInterval(timer);window.removeEventListener("puffle-privacy-change",changed);};
 },[path]);
 return null;
}


