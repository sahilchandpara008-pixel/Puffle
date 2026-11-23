import { createClient } from "npm:@supabase/supabase-js@2.49.8";
import {
  bunnyDownloadUrl, bunnyObjectPath, bunnyStorageRequest, readBunnyStorage, removeBunnyObject,
} from "../_shared/bunny-storage.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const auth = { persistSession: false, autoRefreshToken: false };
const columns = "id,name,size_bytes,mime,storage_path,created_at,storage_provider,storage_lock_until";
const json = (body: unknown, status = 200) => Response.json(body, {
  status, headers: { "cache-control": "no-store" },
});
const db = createClient(url, service, { auth });

class CloudError extends Error {
  constructor(message: string, public status: number) { super(message); }
}

function requireBunny() {
  const config = readBunnyStorage((name) => Deno.env.get(name));
  if (!config) throw new CloudError("Cloud provider temporarily unavailable", 503);
  return config;
}

async function acquire(userId: string, id: string, provider: string, previous: string | null) {
  if (previous && Date.parse(previous) > Date.now()) {
    throw new CloudError("File is being processed. Try again shortly.", 409);
  }
  // The lease outlives the upstream request timeout. Retries can recover after a worker stops.
  const lease = new Date(Date.now() + 5 * 60_000).toISOString();
  let query = db.from("cloud_files").update({ storage_lock_until: lease })
    .eq("id", id).eq("user_id", userId).eq("storage_provider", provider);
  query = previous ? query.eq("storage_lock_until", previous) : query.is("storage_lock_until", null);
  const { data, error } = await query.select("id").maybeSingle();
  if (error || !data) throw new CloudError("File is being processed. Try again shortly.", 409);
  return lease;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const sb = createClient(url, anon, { auth, global: { headers: {
    Authorization: req.headers.get("Authorization") ?? "",
  } } });
  try {
    const { data: { user }, error: userError } = await sb.auth.getUser();
    if (userError || !user) return json({ error: "Sign in required" }, 401);
    if (user.is_anonymous) return json({ error: "Account required" }, 403);

    const body = await req.json().catch(() => null);
    if (!body) return json({ error: "Invalid request" }, 400);
    const bucket = sb.storage.from("cloud");
    const staging = db.storage.from("cloud");

    if (body.action === "upload") {
      const name = typeof body.name === "string"
        ? body.name.trim().replace(/[\\/\0]/g, "_").slice(0, 180) : "";
      const size = body.size;
      if (!name || !Number.isSafeInteger(size) || size <= 0) return json({ error: "Invalid file" }, 400);

      const path = `${user.id}/${crypto.randomUUID()}/${name === "." || name === ".." ? "file" : name}`;
      const bunny = readBunnyStorage((key) => Deno.env.get(key));
      const { data: file, error } = bunny
        ? await db.rpc("reserve_bunny_cloud_file", { p_user: user.id, p_path: path, p_name: name, p_size: size }).single()
        : await sb.from("cloud_files").insert({
          user_id: user.id, name, storage_path: path, size_bytes: size, mime: "application/octet-stream",
        }).select(columns).single();
      if (error || !file) return json({ error: "Storage full or not allowed" }, error?.code === "42501" ? 403 : 400);

      const { data: upload, error: uploadError } = await bucket.createSignedUploadUrl(path);
      if (uploadError || !upload) {
        await db.from("cloud_files").delete().eq("id", file.id).eq("user_id", user.id);
        return json({ error: "Could not prepare upload" }, 400);
      }
      return json({ file, upload });
    }

    if (!["download", "delete", "finalize"].includes(body.action)) {
      return json({ error: "Unknown action" }, 400);
    }
    const { data: file, error: lookupError } = await sb.from("cloud_files").select(columns)
      .eq("id", String(body.id ?? "")).eq("user_id", user.id).maybeSingle();
    if (lookupError || !file) return json({ error: "File not found" }, 404);
    const provider = file.storage_provider;
    if (body.action === "download") {
      if (provider === "bunny_pending") throw new CloudError("Upload is not complete", 409);
      if (provider === "bunny") {
        const path = bunnyObjectPath(user.id, file.id);
        return json({ url: await bunnyDownloadUrl(requireBunny(), path, Math.floor(Date.now() / 1000) + 900) });
      }
      const { data, error } = await bucket.createSignedUrl(file.storage_path, 3600);
      if (error || !data?.signedUrl) return json({ error: "Could not open file" }, 404);
      return json({ url: data.signedUrl });
    }

    if (body.action === "finalize" && provider !== "bunny_pending") return json({ file });

    const config = provider === "supabase" ? null : requireBunny();
    const lease = await acquire(user.id, file.id, provider, file.storage_lock_until);
    try {
      if (body.action === "delete") {
        if (config) await removeBunnyObject(config, bunnyObjectPath(user.id, file.id));
        const { error: removeError } = await staging.remove([file.storage_path]);
        if (removeError) throw new CloudError("Could not remove staged file", 502);
        const { error } = await db.from("cloud_files").delete()
          .eq("id", file.id).eq("user_id", user.id).eq("storage_lock_until", lease);
        if (error) throw new CloudError("Could not remove file record", 503);
        return json({ ok: true });
      }

      const upstream = AbortSignal.timeout(100_000);
      const { data, error } = await staging.createSignedUrl(file.storage_path, 120);
      if (error || !data?.signedUrl) throw new CloudError("Upload bytes not found", 409);
      const staged = await fetch(data.signedUrl, { signal: upstream, redirect: "error" });
      if (!staged.ok || !staged.body || Number(staged.headers.get("content-length")) !== file.size_bytes) {
        await staged.body?.cancel();
        throw new CloudError("Upload is incomplete or the file size changed", 409);
      }
      const object = bunnyObjectPath(user.id, file.id);
      const unsigned = new URL(object, config!.cdn);
      const probe = await fetch(unsigned, { method: "HEAD", redirect: "error", signal: upstream });
      if (probe.status !== 403 && probe.status !== 401) {
        await staged.body.cancel();
        throw new CloudError("Cloud download protection is not configured", 503);
      }
      const copied = await bunnyStorageRequest(config!, object, {
        method: "PUT", body: staged.body, signal: upstream,
        headers: { "content-type": "application/octet-stream", "content-length": String(file.size_bytes) },
      });
      await copied.body?.cancel();
      if (!copied.ok) throw new CloudError("Cloud transfer failed. Try again.", 502);

      const signed = await bunnyDownloadUrl(config!, object, Math.floor(Date.now() / 1000) + 90);
      const probeSigned = await fetch(signed, { method: "HEAD", redirect: "error", signal: upstream });
      if (!probeSigned.ok) throw new CloudError("Cloud download is not ready. Try again.", 502);

      const { data: saved, error: saveError } = await db.from("cloud_files")
        .update({ storage_provider: "bunny", storage_lock_until: null })
        .eq("id", file.id).eq("user_id", user.id).eq("storage_lock_until", lease).select(columns).single();
      if (saveError || !saved) throw new CloudError("Could not finish upload. Try again.", 503);

      const { error: cleanupError } = await staging.remove([file.storage_path]);
      if (cleanupError) console.warn("Cloud staging cleanup will be retried at file deletion");
      return json({ file: saved });
    } finally {
      const { error } = await db.from("cloud_files").update({ storage_lock_until: null })
        .eq("id", file.id).eq("user_id", user.id).eq("storage_lock_until", lease);
      if (error) console.warn("Cloud transfer lease will expire");
    }
  } catch (error) {
    if (error instanceof CloudError) return json({ error: error.message }, error.status);
    console.error("Cloud storage request failed");
    return json({ error: "Cloud storage temporarily unavailable" }, 503);
  }
});
