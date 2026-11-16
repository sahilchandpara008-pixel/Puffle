"use client";
import {useEffect,useState} from "react";
import {trackWebEvent} from "@/components/MetaPixel";
export default function StoreButton({store}:{store:string}){
 const [href,setHref]=useState(store);
 useEffect(()=>{
  const incoming=new URLSearchParams(location.search),referrer=new URLSearchParams();
  for(const key of ["utm_source","utm_medium","utm_campaign","utm_content","utm_term"]){const v=incoming.get(key);if(v)referrer.set(key,v.slice(0,200));}
  const url=new URL(store);if(referrer.size)url.searchParams.set("referrer",referrer.toString());setHref(url.toString());
 },[store]);
 return <a href={href} className="btn inline-block px-8 py-4" onClick={async e=>{
  e.preventDefault();const target=e.currentTarget.href;
  await Promise.race([trackWebEvent("Lead"),new Promise(resolve=>setTimeout(resolve,750))]);
  location.assign(target);
 }}>Get Puffle on Google Play</a>;
}
