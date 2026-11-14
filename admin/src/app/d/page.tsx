import SiteShell from "@/components/SiteShell";
import DownloadButton from "./DownloadButton";

export const metadata = { title: "Download Puffle" };


export default function Download() {
  return (
    <SiteShell>
      <main className="mx-auto max-w-md px-4 py-16 text-center space-y-4">
        <div className="mx-auto h-20 w-20 rounded-3xl bg-brand grid place-items-center text-2xl font-bold text-white">PF</div>
        <h1 className="text-3xl font-bold text-slate-900">Get Puffle for Android</h1>
        <p className="text-slate-600">15 GB free cloud storage, creator channels and Premium plans.</p>
        <DownloadButton />
        <p className="text-xs text-slate-500">If your phone asks, allow “install unknown apps” for your browser. Android 7.0 or newer.</p>
      </main>
    </SiteShell>
  );
}

