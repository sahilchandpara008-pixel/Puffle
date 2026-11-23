"use client";

import { useCallback, useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/client";

type Video = { id: string; title: string; date: string; bytes: number; reason: string; thumbnail: string | null };
type Inventory = {
  configured: boolean; total: number; used: number; unusedBytes: number;
  unused: Video[]; remaining: number; monthlyInr: number | null;
};

const gb = (bytes: number) => `${(bytes / 1e9).toLocaleString("en-IN", { maximumFractionDigits: 3 })} GB`;
const date = (value: string) => new Date(value).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" });
const rupees = (value: number) => value.toLocaleString("en-IN", { style: "currency", currency: "INR" });

export default function StorageCleanup() {
  const [list, setList] = useState<Inventory | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [busy, setBusy] = useState(true);
  const [message, setMessage] = useState("");
  const [failure, setFailure] = useState("");
  const refresh = useCallback(async () => {
    setBusy(true);
    setFailure("");
    try {
      const { data, error } = await supabaseBrowser().functions.invoke<Inventory>("bunny-stream", { body: { action: "inventory" } });
      if (error || !data) throw new Error("Could not load the Bunny library.");
      setList(data); setSelected([]);
    } catch {
      setFailure("Could not load the Bunny library. Please retry.");
    } finally { setBusy(false); }
  }, []);
  useEffect(() => { void refresh(); }, [refresh]);

  async function remove(ids: string[]) {
    if (busy || !ids.length || !window.confirm(`Permanently delete ${ids.length} unused video${ids.length === 1 ? "" : "s"}? This cannot be undone.`)) return;
    setBusy(true); setFailure(""); setMessage("");
    let deleted = 0, kept = 0, failed = 0;
    try {
      for (let offset = 0; offset < ids.length; offset += 20) {
        const result = await supabaseBrowser().functions.invoke("bunny-stream", {
          body: { action: "delete", ids: ids.slice(offset, offset + 20) },
        });
        if (result.error) throw result.error;
        deleted += result.data.deleted;
        kept += result.data.kept;
        failed += result.data.failed;
      }
      setMessage(`${deleted} deleted, ${kept} kept after rechecking, ${failed} failed.`);
      await refresh();
    } catch {
      setFailure(`Stopped after deleting ${deleted} videos. Refresh the list before retrying.`);
      setBusy(false);
    }
  }

  return <section className="space-y-4">
    <div className="flex flex-wrap gap-2">
      <button className="btn" disabled={busy} onClick={() => void refresh()}>{busy ? "Working…" : "Refresh"}</button>
      {!!selected.length && <button className="btn" disabled={busy} onClick={() => void remove(selected)}>Delete selected ({selected.length})</button>}
      {!!list?.unused?.length && !list.remaining && <button className="btn" disabled={busy} onClick={() => void remove(list.unused.map(video => video.id))}>Delete all unused</button>}
    </div>
    {message && <p role="status">{message}</p>}
    {failure && <p role="alert">{failure}</p>}
    {list?.configured === false && <p>Add the Bunny Stream credentials in Puffle’s server secrets to load your library.</p>}
    {list?.configured && <>
      <div className="grid gap-3 sm:grid-cols-4">
        <p>Total <strong>{list.total}</strong></p>
        <p>Used <strong>{list.used}</strong></p>
        <p>Unused <strong>{list.unused.length}</strong></p>
        <p>Reclaimable <strong>{gb(list.unusedBytes)}{list.monthlyInr != null && ` · ${rupees(list.monthlyInr)}/month`}</strong></p>
      </div>
      <p>Uploads from the last 24 hours are excluded. Times are in IST.</p>
      {!!list.remaining && <p>The inventory exceeded the scan limit. Totals cover the videos scanned.</p>}
      {!list.unused.length && <p>No unused videos to clean up.</p>}
      <ul className="divide-y rounded-xl border">
        {list.unused.map(video => <li key={video.id} className="flex flex-wrap items-center gap-3 p-3">
          <input type="checkbox" aria-label={`Select ${video.title}`} disabled={busy} checked={selected.includes(video.id)}
            onChange={event => setSelected(current => event.target.checked ? [...current, video.id] : current.filter(id => id !== video.id))} />
          {video.thumbnail && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={video.thumbnail} alt="" className="h-12 w-20 rounded object-cover" />
          )}
          <div className="min-w-40 flex-1">
            <p className="font-medium">{video.title}</p>
            <p className="text-sm">{video.reason} · {gb(video.bytes)} · {date(video.date)}</p>
          </div>
          <button className="btn" disabled={busy} onClick={() => void remove([video.id])}>Delete</button>
        </li>)}
      </ul>
    </>}
  </section>;
}
