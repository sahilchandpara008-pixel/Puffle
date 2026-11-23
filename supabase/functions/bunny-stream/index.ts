import { createClient } from "npm:@supabase/supabase-js@2.49.8";
import { bunnyCdnUrl, encodeState, hmac, previewPlaylist, streamApi, streamConfig,
  streamKey, tusAuthorization, uuid, type StreamConfig } from "../_shared/bunny-stream.ts";

const project = Deno.env.get("SUPABASE_URL")!;
const auth = { persistSession: false, autoRefreshToken: false };
const db = createClient(project, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth });
const headers = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "POST, GET, OPTIONS",
  "cache-control": "no-store",
};
const json = (value: unknown, status = 200) => Response.json(value, { status, headers });
const nowSeconds = () => Math.floor(Date.now() / 1000);
const hour = 3600;
const dayMs = 86_400_000;

type Video = {
  guid: string; title: string; dateUploaded: string; status: number; length?: number; storageSize?: number;
};
type Reservation = {
  id: string; channel_id: string; uploader_id: string; purpose: string; state: string;
  library_id: string; created_at: string; upload_expires_at: string | null; delete_requested_at: string | null;
};
function checked<T>(result: { data: T; error: unknown }): T {
  if (result.error) throw new Error("Could not read or update the video record");
  return result.data;
}

async function remoteVideo(config: StreamConfig, id: string): Promise<Video | null> {
  const response = await streamApi(config, `/${id}`);
  if (response.status === 404) return null;
  if (!response.ok) throw new Error("Bunny video lookup failed");
  return await response.json();
}

async function referenced(ids: string[]) {
  if (!ids.length) return new Set<string>();
  const [main, trailer] = await Promise.all([
    db.from("post_items").select("bunny_video_id").in("bunny_video_id", ids),
    db.from("post_items").select("trailer_bunny_video_id").in("trailer_bunny_video_id", ids),
  ]);
  return new Set([
    ...(checked(main) ?? []).map((row) => row.bunny_video_id),
    ...(checked(trailer) ?? []).map((row) => row.trailer_bunny_video_id),
  ]);
}

async function deleteUnused(config: StreamConfig, id: string, manual: boolean) {
  if (manual) {
    const video = await remoteVideo(config, id);
    if (video && !(Date.parse(video.dateUploaded) <= Date.now() - dayMs)) return false;
    // An old orphan may precede the Puffle reservation table. Register it before locking it.
    if (video) checked(await db.from("bunny_videos").upsert({
      id, library_id: config.library, created_at: new Date(video.dateUploaded).toISOString(),
    }, { onConflict: "id", ignoreDuplicates: true }));
  }
  const claim = checked(await db.rpc("claim_bunny_video_delete", {
    p_id: id, p_library: config.library, p_manual: manual,
  }));
  if (!claim) return false;
  const result = await streamApi(config, `/${id}`, { method: "DELETE" });
  if (!result.ok && result.status !== 404) throw new Error("Bunny deletion failed");
  await result.body?.cancel();
  checked(await db.from("bunny_videos").delete().eq("id", id).eq("state", "deleting"));
  return true;
}

async function sync(config: StreamConfig) {
  const rows = checked(await db.from("bunny_videos").select("*").eq("library_id", config.library)
    .lte("next_check_at", new Date().toISOString())
    .or("state.in.(waiting,processing,deleting),delete_requested_at.not.is.null")
    .order("next_check_at").limit(20)) as Reservation[];
  const results = await Promise.allSettled(rows.map(async (row) => {
    const next = new Date(Date.now() + 120_000).toISOString();
    checked(await db.from("bunny_videos").update({ next_check_at: next }).eq("id", row.id));
    if (row.delete_requested_at) return await deleteUnused(config, row.id, false);
    const video = await remoteVideo(config, row.id);
    let state = video ? encodeState(video.status) : "failed";
    if (state === "ready") {
      const path = `/${row.id}/playlist.m3u8`;
      const expiry = nowSeconds() + 90;
      const [signed, unsigned] = await Promise.all([
        fetch(await bunnyCdnUrl(config, path, expiry), { method: "HEAD", redirect: "error", signal: AbortSignal.timeout(7000) }),
        fetch(config.origin + path, { method: "HEAD", redirect: "error", signal: AbortSignal.timeout(7000) }),
      ]);
      if (!signed.ok || ![401, 403].includes(unsigned.status)) state = "processing";
    }
    if (state === "waiting" && Date.parse(row.created_at) < Date.now() - dayMs) state = "failed";
    if (state === "ready" && row.purpose === "main") {
      if (video?.length && Number.isFinite(video.length)) {
        checked(await db.from("post_items").update({ duration_s: Math.round(video.length) })
          .eq("bunny_video_id", row.id));
      }
      checked(await db.from("post_items").update({ thumbnail_key: `${row.channel_id}/bunny/${row.id}` })
        .eq("bunny_video_id", row.id).is("thumbnail_key", null));
    }
    checked(await db.from("bunny_videos").update({ state }).eq("id", row.id).is("delete_requested_at", null));
    return state;
  }));
  return json({ processed: rows.length, retry: results.filter((r) => r.status === "rejected").length });
}

async function inventory(config: StreamConfig, includeThumbnails: boolean) {
  const unused: Array<Record<string, unknown>> = [];
  let total = 0, used = 0, unusedBytes = 0, remaining = 0;
  for (let page = 1; page <= 100; page++) {
    const result = await streamApi(config, `?page=${page}&itemsPerPage=100&orderBy=date`);
    if (!result.ok) throw new Error("Could not list Bunny videos");
    const data = await result.json() as { items: Video[]; totalItems: number };
    const items = data.items.filter((item) => uuid.test(item.guid));
    const linked = await referenced(items.map((item) => item.guid));
    total += items.length;
    used += linked.size;
    remaining = Math.max(0, data.totalItems - total);
    for (const entry of items) {
      const uploaded = Date.parse(entry.dateUploaded);
      if (linked.has(entry.guid) || !(uploaded <= Date.now() - dayMs)) continue;
      const state = encodeState(entry.status);
      const bytes = Math.max(0, Number(entry.storageSize) || 0);
      unusedBytes += bytes;
      unused.push({
        id: entry.guid, title: entry.title, date: entry.dateUploaded, bytes,
        reason: state === "waiting" ? "Upload never finished" : state === "processing"
          ? "Stuck in processing" : state === "failed" ? "Processing failed" : "Not used by any post",
        thumbnail: includeThumbnails && state === "ready" && unused.length < 100
          ? await bunnyCdnUrl(config, `/${entry.guid}/thumbnail.jpg`, nowSeconds() + 900) : null,
      });
    }
    if (!remaining || data.items.length < 100) break;
  }
  const rate = Number(Deno.env.get("BUNNY_STREAM_INR_PER_GB_MONTH") || "");
  return { total, used, unusedBytes, unused, remaining,
    monthlyInr: Number.isFinite(rate) && rate > 0 ? unusedBytes / 1e9 * rate : null };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
  try {
    const config = streamConfig((key) => Deno.env.get(key));
    if (request.method === "GET") {
      const params = new URL(request.url).searchParams;
      const id = params.get("video") ?? "";
      const expiry = Number(params.get("expires"));
      const actual = params.get("signature") ?? "";
      if (!config || !uuid.test(id) || !Number.isInteger(expiry) || expiry <= nowSeconds()
        || expiry > nowSeconds() + 900 || !/^[a-zA-Z0-9_-]{43}$/.test(actual)) return json({ error: "Preview expired" }, 403);
      const signature = await hmac(config.cdnKey, `puffle-preview:${id}:${expiry}`);
      let difference = 0;
      for (let index = 0; index < signature.length; index++) difference |= signature.charCodeAt(index) ^ actual.charCodeAt(index);
      if (difference !== 0) return json({ error: "Preview expired" }, 403);
      return new Response(await previewPlaylist(config, id, expiry), {
        headers: { ...headers, "content-type": "application/vnd.apple.mpegurl" },
      });
    }
    if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
    const body = await request.json().catch(() => null);
    if (!body || typeof body.action !== "string") return json({ error: "Invalid request" }, 400);
    if (body.action === "sync") {
      const valid = checked(await db.rpc("meta_cron_ok", { p_key: request.headers.get("x-cron-key") ?? "" }));
      if (valid !== true) return json({ error: "Forbidden" }, 403);
      return config ? await sync(config) : json({ configured: false });
    }
    const sb = createClient(project, Deno.env.get("SUPABASE_ANON_KEY")!, {
      auth, global: { headers: { Authorization: request.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error } = await sb.auth.getUser();
    if (error || !user) return json({ error: "Sign in required" }, 401);

    if (body.action === "create") {
      if (!config) return json({ configured: false });
      if (!uuid.test(body.channel_id) || !["main", "trailer"].includes(body.purpose)
        || typeof body.title !== "string" || typeof body.content_type !== "string"
        || !/^video\/[a-z\d.+-]+$/i.test(body.content_type)) return json({ error: "Invalid video" }, 400);
      if (user.is_anonymous || checked(await sb.rpc("can_post_to_channel", { p_channel: body.channel_id })) !== true)
        return json({ error: "Upload not allowed" }, 403);
      const channel = checked(await sb.from("channels").select("id").eq("id", body.channel_id).maybeSingle());
      if (!channel) return json({ error: "Channel not found" }, 404);
      const expiry = nowSeconds() + 6 * hour;
      let id = String(body.resume_id ?? "");
      if (uuid.test(id)) {
        const previous = checked(await db.from("bunny_videos").select("*").eq("id", id)
          .eq("library_id", config.library).eq("channel_id", body.channel_id)
          .eq("uploader_id", user.id).eq("purpose", body.purpose).maybeSingle()) as Reservation | null;
        if (!previous || previous.delete_requested_at || !["waiting", "processing", "ready"].includes(previous.state))
          return json({ error: "The previous upload is no longer available" }, 409);
      } else {
        const response = await streamApi(config, "", { method: "POST",
          body: JSON.stringify({ title: body.title.trim().slice(0, 160) || "Puffle video" }) });
        if (!response.ok) throw new Error("Could not create Bunny video");
        id = (await response.json()).guid;
        if (!uuid.test(id)) throw new Error("Invalid Bunny video response");
        checked(await db.from("bunny_videos").insert({ id, library_id: config.library,
          channel_id: body.channel_id, uploader_id: user.id, purpose: body.purpose,
          upload_expires_at: new Date(expiry * 1000).toISOString() }));
      }
      // The original TUS expiry is retained on the reservation for cleanup.
      const stored = checked(await db.from("bunny_videos").select("upload_expires_at,state").eq("id", id).single());
      const grantExpiry = Math.floor(Date.parse(stored.upload_expires_at) / 1000);
      if (grantExpiry <= nowSeconds()) return json({ error: "Upload expired. Re-select the file to retry." }, 409);
      return json({ configured: true, id, key: `${body.channel_id}/bunny/${id}`,
        headers: await tusAuthorization(config, id, grantExpiry) });
    }

    if (body.action === "urls") {
      if (!config) return json({ urls: {} });
      if (!["thumbnail", "full", "trailer", "preview"].includes(body.kind) || !Array.isArray(body.keys) ||
        body.keys.length > 80 || body.keys.some((key: unknown) => typeof key !== "string" || !streamKey.test(key)))
        return json({ error: "Invalid video selection" }, 400);
      const field = body.kind === "thumbnail" ? "thumbnail_key" : body.kind === "trailer" ? "trailer_key" : "media_key";
      // The caller's post and channel policies decide membership and audience before any URL is signed.
      const items = checked(await sb.from("post_items")
        .select("media_key,thumbnail_key,trailer_key,is_premium,bunny_video_id,trailer_bunny_video_id")
        .in(field, body.keys));
      const ids = [...new Set((items ?? []).map((row) =>
        body.kind === "trailer" ? row.trailer_bunny_video_id : row.bunny_video_id).filter(Boolean))];
      const records = ids.length ? checked(await db.from("bunny_videos").select("id,state,library_id").in("id", ids)) : [];
      const ready = new Set(records?.filter((row) => row.state === "ready" && row.library_id === config.library).map((row) => row.id));
      const [admin, ads, premium] = body.kind === "thumbnail" ? [false, false, false] : await Promise.all([
        sb.rpc("is_admin").then(checked), sb.rpc("source_of").then(checked), sb.rpc("can_full_premium").then(checked),
      ]);
      if (body.kind !== "thumbnail" && !admin && user.is_anonymous && ads !== "ads") return json({ urls: {} });
      const expiry = nowSeconds() + 900;
      const urls: Record<string, string> = {};
      await Promise.all((items ?? []).map(async (row) => {
        const id = body.kind === "trailer" ? row.trailer_bunny_video_id : row.bunny_video_id;
        const key = row[field];
        if (!key || !id || !ready.has(id)) return;
        const base = `/${id}/`;
        if (body.kind === "thumbnail") {
          urls[key] = await bunnyCdnUrl(config, base + "thumbnail.jpg", expiry);
        } else if (body.kind === "preview" && row.is_premium && ads === "ads") {
          const token = await hmac(config.cdnKey, `puffle-preview:${id}:${expiry}`);
          urls[key] = `${project}/functions/v1/bunny-stream?video=${id}&expires=${expiry}&signature=${token}`;
        } else if (body.kind === "trailer" || (body.kind === "full" && (!row.is_premium || premium || admin))) {
          urls[key] = await bunnyCdnUrl(config, base + "playlist.m3u8", expiry, base);
        }
      }));
      return json({ urls });
    }

    if (["inventory", "delete"].includes(body.action)) {
      if (checked(await sb.rpc("is_owner")) !== true) return json({ error: "Owner required" }, 403);
      if (!config) return json({ configured: false });
      if (body.action === "inventory") return json({ configured: true, ...await inventory(config, true) });
      const ids: string[] = body.all === true
        ? (await inventory(config, false)).unused.slice(0, 20).map((row) => String(row.id))
        : Array.isArray(body.ids) ? [...new Set(body.ids.map(String))] : [];
      if (ids.length > 20 || ids.some((id) => !uuid.test(id))) return json({ error: "Choose up to 20 videos" }, 400);
      const results = await Promise.allSettled(ids.map((id) => deleteUnused(config, id, true)));
      return json({ deleted: results.filter((r) => r.status === "fulfilled" && r.value).length,
        kept: results.filter((r) => r.status === "fulfilled" && !r.value).length,
        failed: results.filter((r) => r.status === "rejected").length });
    }
    return json({ error: "Unknown action" }, 400);
  } catch (error) {
    console.error("Bunny Stream operation failed", error instanceof Error ? error.message : "unknown error");
    return json({ error: "Video service temporarily unavailable" }, 503);
  }
});
