import SiteShell from "@/components/SiteShell";
import DownloadButton from "./DownloadButton";

export const metadata = { title: "Download Puffle" };
const APK = process.env.NEXT_PUBLIC_APK_URL || "https://github.com/smitkhachariya2002-collab/Puffle/releases/download/latest/Puffle.apk";
const ADS_APK = process.env.NEXT_PUBLIC_ADS_APK_URL || APK.replace(/Puffle\.apk$/, "Puffle-ads.apk");

export default function Download() {
  return (
    <SiteShell>
      <main className="mx-auto max-w-md px-4 py-16 text-center space-y-4">
        <div className="mx-auto h-20 w-20 rounded-3xl bg-brand grid place-items-center text-2xl font-bold text-white">PF</div>
        <h1 className="text-3xl font-bold text-slate-900">Get Puffle for Android</h1>
        <p className="text-slate-600">15 GB free cloud storage, creator channels and Premium plans.</p>
        <DownloadButton apk={APK} adsApk={ADS_APK} />
        <p className="text-xs text-slate-500">If your phone asks, allow “install unknown apps” for your browser. Android 7.0 or newer.</p>
      </main>
    </SiteShell>
  );
}
