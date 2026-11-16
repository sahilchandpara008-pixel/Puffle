import Link from "next/link";
import {supabaseServer} from "@/lib/supabase/server";
import StoreButton from "./StoreButton";
import SiteShell from "@/components/SiteShell";
import DownloadButton from "../d/DownloadButton";
export const dynamic="force-dynamic";
export default async function GetApp(){
 const {data}=await supabaseServer().rpc("meta_landing_public");
 return <SiteShell><main className="mx-auto max-w-3xl px-6 py-20 text-center">
  <img src="/icon.svg" alt="" className="mx-auto mb-8 h-24 w-24"/>
  <h1 className="text-4xl font-semibold">{data?.page_title??"Puffle"}</h1>
  <p className="mt-4 text-xl text-slate-300">{data?.page_subtitle??"Your cloud and channels"}</p>
  <p className="my-8 text-slate-300">Keep your files in your personal cloud and discover available creator channels. Some features require a Premium plan. Google Play testing availability depends on your country and account.</p>
  <div className="flex flex-wrap justify-center gap-4"><DownloadButton label="Download Puffle for Android"/><StoreButton store={data?.store_url??"https://play.google.com/store/apps/details?id=com.pufflecloud.app"}/></div>
  <p className="mt-8 text-sm text-slate-400"><Link href="/privacy" className="underline">Privacy Policy</Link> · <Link href="/terms" className="underline">Terms</Link> · <Link href="/" className="underline">About Puffle</Link></p>
 </main></SiteShell>;
}
