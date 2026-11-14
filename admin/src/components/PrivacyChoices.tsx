"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
export const CHOICE_KEY="puffle_privacy_20261115";
export type WebChoices={analytics:boolean;advertising:boolean;google:boolean;saved:number};
export function readWebChoices():WebChoices|null {
 try {const value=JSON.parse(localStorage.getItem(CHOICE_KEY)??"null");return value&&typeof value.analytics==="boolean"&&typeof value.advertising==="boolean"&&typeof value.google==="boolean"&&Date.now()-value.saved<180*86400000?value:null;}catch{return null;}
}
export function hasAdvertisingConsent(){return readWebChoices()?.advertising===true;}
export default function PrivacyChoices(){
 const [open,setOpen]=useState(false),[advertising,setAdvertising]=useState(false),[google,setGoogle]=useState(false);
 useEffect(()=>{
  const value=readWebChoices();setOpen(!value);setAdvertising(value?.advertising??false);setGoogle(value?.google??false);
  const show=()=>{const next=readWebChoices();setAdvertising(next?.advertising??false);setGoogle(next?.google??false);setOpen(true);};
  window.addEventListener("puffle-privacy-open",show);return()=>window.removeEventListener("puffle-privacy-open",show);
 },[]);
 const save=(a:boolean,m:boolean,g:boolean)=>{
  try {localStorage.setItem(CHOICE_KEY,JSON.stringify({analytics:a,advertising:m,google:g,saved:Date.now()}));}catch{/* Keep essential-only behaviour if storage is blocked. */}
  if(!m){
   window.fbq?.("consent","revoke");
   for(const name of ["_fbc","_fbp"]){document.cookie=name+"=; Max-Age=0; Path=/; SameSite=Lax";document.cookie=name+"=; Max-Age=0; Path=/; Domain="+location.hostname+"; SameSite=Lax";}
   try {sessionStorage.removeItem("orbix_fbclid");sessionStorage.removeItem("orbix_ad");}catch{}
  }
  if(!g){window.gtag?.("consent","update",{ad_storage:"denied",analytics_storage:"denied",ad_user_data:"denied",ad_personalization:"denied"});
   for(const c of document.cookie.split(';')){const name=c.trim().split('=')[0];if(/^(_ga|_gcl|_gid)/.test(name)){document.cookie=name+'=; Max-Age=0; Path=/; SameSite=Lax';document.cookie=name+'=; Max-Age=0; Path=/; Domain='+location.hostname+'; SameSite=Lax';}}}
  window.dispatchEvent(new Event("puffle-privacy-change"));setOpen(false);
 };
 if(!open)return null;
 return <section role="dialog" aria-modal="false" aria-labelledby="privacy-title" className="privacy-choice">
  <div><h2 id="privacy-title" className="text-lg font-semibold">Your privacy choices</h2><p className="mt-2 text-sm leading-relaxed text-slate-300">Essential storage keeps the website and downloads working. Optional measurement helps us understand visits and improve our ads. If you allow advertising measurement, Meta and/or Google (according to your choices) may receive page and download events, click/cookie identifiers, IP address and browser information. You can change your choice below at any time.</p><Link href="/privacy" className="mt-2 inline-block text-sm text-teal-200 underline">How data is used</Link></div>
  <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2 text-sm"><label className="flex items-center gap-2"><input type="checkbox" checked={advertising} onChange={e=>setAdvertising(e.target.checked)}/>Meta advertising measurement</label><label className="flex items-center gap-2"><input type="checkbox" checked={google} onChange={e=>setGoogle(e.target.checked)}/>Google advertising measurement</label></div>
  <div className="mt-5 flex flex-wrap gap-2"><button type="button" className="btn-ghost" onClick={()=>save(false,false,false)}>Essential only</button><button type="button" className="btn-ghost" onClick={()=>save(false,advertising,google)}>Save choices</button><button type="button" className="btn" onClick={()=>save(false,true,true)}>Allow optional measurement</button></div>
 </section>;
}
export function PrivacyChoicesButton(){return <button type="button" className="text-left underline underline-offset-4" onClick={()=>window.dispatchEvent(new Event("puffle-privacy-open"))}>Privacy choices</button>;}

