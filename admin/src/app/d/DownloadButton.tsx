"use client";
import { useEffect, useState } from "react";
import {usePathname} from "next/navigation";
import { APK_URL, ADS_APK_URL } from "@/lib/downloads";
import {trackGoogleDownload} from "@/components/GoogleTags";
import { fromAd, trackWebEvent } from "@/components/MetaPixel";

/** Download button. People who came from an ad get the ads build; the tap is sent to Meta as a Lead. */
export default function DownloadButton({ apk = APK_URL, adsApk = ADS_APK_URL, label = "Download APK", className = "btn px-8 py-3" }: { apk?: string; adsApk?: string; label?: string; className?: string }) {
  const [href, setHref] = useState(apk);
  const path=usePathname();
  useEffect(() => { setHref(fromAd()?adsApk:apk); }, [adsApk,apk,path]);
  const onClick = async (event:React.MouseEvent<HTMLAnchorElement>) => {
    const target=fromAd()?adsApk:apk;event.currentTarget.href=target;
    if(event.ctrlKey||event.metaKey||event.shiftKey||event.altKey)return;
    event.preventDefault();
    await Promise.race([Promise.allSettled([trackWebEvent("Lead"),trackGoogleDownload()]),new Promise(resolve=>setTimeout(resolve,750))]);
    location.assign(target);
  };
  return <a href={href} onClick={onClick} className={className} download>{label}</a>;
}


