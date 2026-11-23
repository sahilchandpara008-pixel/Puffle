"use client";
import { useEffect, useRef, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/client";
import { isBunnyKey, mediaUrls } from "@/lib/stream-media";

/** Fetch a signed URL only when the admin asks to preview the saved file. */
export default function SavedMediaPreview({ storageKey, label, mime, poster, kind = "full" }: { storageKey: string; label: string; mime: string; poster?: string; kind?: "full" | "trailer" }) {
  const [url, setUrl] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const pending = useRef(false);
  const player = useRef<HTMLVideoElement | null>(null);
  const bunny = isBunnyKey(storageKey);
  useEffect(() => {
    const element = player.current;
    if (!bunny || !url || !element || element.canPlayType("application/vnd.apple.mpegurl")) return;
    let active = true;
    let destroy: (() => void) | undefined;
    void import("hls.js").then(({ default: Hls }) => {
      if (!active) return;
      if (!Hls.isSupported()) { setError("This browser does not support HLS playback."); return; }
      const hls = new Hls();
      destroy = () => hls.destroy();
      hls.on(Hls.Events.ERROR, (_, event) => {
        if (event.fatal) setError("The video is unavailable. Retry after it finishes encoding.");
      });
      hls.loadSource(url);
      hls.attachMedia(element);
    }).catch(() => { if (active) setError("Could not load the video player."); });
    return () => { active = false; destroy?.(); };
  }, [bunny, url]);
  const load = async () => {
    if (pending.current) return;
    pending.current = true; setLoading(true); setError("");
    try {
      const links = await mediaUrls(supabaseBrowser(), [storageKey], kind);
      if (!links[storageKey]) throw new Error("The video may still be encoding. Try again shortly.");
      setUrl(links[storageKey]);
    } catch (e) { setError(e instanceof Error ? e.message : "Could not load preview."); }
    finally { pending.current = false; setLoading(false); }
  };
  return <details className="mt-2 rounded-lg border p-2" onToggle={event => {
    if (event.currentTarget.open) { if (!url) void load(); }
    else player.current?.pause();
  }}>
    <summary className="cursor-pointer text-sm font-medium">{label}</summary>
    {loading && <p role="status" className="mt-2 text-xs">Loading preview…</p>}
    {url && (mime.startsWith("video") ? <video ref={element => {
      player.current = element;
      if (element && (!bunny || element.canPlayType("application/vnd.apple.mpegurl")) && element.getAttribute("src") !== url) element.src = url;
    }} controls playsInline preload="metadata" poster={poster} aria-label={label} onError={() => setError("This browser could not play the file. Try another browser or replace the video.")} className="mt-2 max-h-96 w-full rounded-lg bg-black" /> :
      /* eslint-disable-next-line @next/next/no-img-element */
      <img src={url} alt={label} className="mt-2 max-h-96 max-w-full rounded-lg object-contain" />)}
    {error && <div className="mt-2 text-xs text-red-700" role="alert">{error} <button type="button" className="underline" disabled={loading} onClick={() => void load()}>Retry preview</button></div>}
  </details>;
}
