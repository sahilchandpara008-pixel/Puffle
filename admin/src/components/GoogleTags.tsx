"use client";
import {useEffect} from "react";
import {usePathname} from "next/navigation";
import {supabaseBrowser} from "@/lib/supabase/client";
import {readWebChoices} from "./PrivacyChoices";
type Settings={web_enabled:boolean;web_method:"direct"|"gtm";conversion_id:string;download_label:string;gtm_id:string};
declare global{interface Window{dataLayer?:unknown[];gtag?:(...args:unknown[])=>void;__puffleGoogle?:{at:number;settings:Settings|null};__puffleGoogleLoaded?:string;__puffleGoogleBlocked?:boolean;}}
const allowed=()=>readWebChoices()?.google===true;
export async function loadGoogle(){
 if(!allowed())return null;
 if(window.__puffleGoogle&&Date.now()-window.__puffleGoogle.at<60000)return window.__puffleGoogle.settings;
 try{const {data,error}=await supabaseBrowser().rpc("google_public");if(error)throw error;
  const s=data as Settings;
  window.__puffleGoogle={at:Date.now(),settings:s?.web_enabled?s:null};
  if(!s?.web_enabled||!allowed()){window.gtag?.("consent","update",{ad_storage:"denied",analytics_storage:"denied",ad_user_data:"denied",ad_personalization:"denied"});return null;}
  const key=s.web_method==="gtm"?s.gtm_id:s.conversion_id;
  if(!(s.web_method==="gtm"?/^GTM-[A-Z0-9]+$/:/^AW-\d+$/).test(key))return null;
  // Old GTM containers cannot be unloaded safely in a running document. Stop all measurement until navigation reloads.
  if(window.__puffleGoogleLoaded&&window.__puffleGoogleLoaded!==s.web_method+":"+key){window.__puffleGoogleBlocked=true;window.gtag?.("consent","update",{ad_storage:"denied",analytics_storage:"denied",ad_user_data:"denied",ad_personalization:"denied"});return null;}
  if(window.__puffleGoogleBlocked)return null;
  window.dataLayer??=[];window.gtag??=(...args:unknown[])=>{window.dataLayer!.push(args);};
  if(!window.__puffleGoogleLoaded){
   window.gtag("consent","default",{ad_storage:"denied",analytics_storage:"denied",ad_user_data:"denied",ad_personalization:"denied"});
   window.gtag("consent","update",{ad_storage:"granted",analytics_storage:"granted",ad_user_data:"granted",ad_personalization:"denied"});
   const script=document.createElement("script");script.async=true;
   if(s.web_method==="gtm"){window.dataLayer.push({"gtm.start":Date.now(),event:"gtm.js"});script.src="https://www.googletagmanager.com/gtm.js?id="+encodeURIComponent(key);}
   else{window.gtag("js",new Date());window.gtag("config",key,{send_page_view:false,allow_ad_personalization_signals:false});script.src="https://www.googletagmanager.com/gtag/js?id="+encodeURIComponent(key);}
   document.head.appendChild(script);window.__puffleGoogleLoaded=s.web_method+":"+key;
  }else window.gtag("consent","update",{ad_storage:"granted",analytics_storage:"granted",ad_user_data:"granted",ad_personalization:"denied"});
  return s;
 }catch{return null;}
}
export async function trackGoogleDownload(){const s=await loadGoogle();if(!s||!allowed())return;
 if(s.web_method==="gtm")window.dataLayer?.push({event:"puffle_apk_download",content_type:"android_apk"});
 else if(s.download_label)window.gtag?.("event","conversion",{send_to:s.conversion_id+"/"+s.download_label});
}
export default function GoogleTags(){const path=usePathname();useEffect(()=>{
 const refresh=()=>{window.__puffleGoogle=undefined;void loadGoogle();};void loadGoogle();window.addEventListener("puffle-privacy-change",refresh);const timer=setInterval(refresh,60000);
 return()=>{clearInterval(timer);window.removeEventListener("puffle-privacy-change",refresh);};},[path]);return null;}
