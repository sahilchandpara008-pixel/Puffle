// Puffle's door to Flixvault's videos.
//
// The Puffle app calls this function (signed-in or guest session). It:
//   1. checks the Puffle user (JWT) and reads their status from Puffle's own
//      database (my_status): ads vs organic, guest, Premium;
//   2. calls Flixvault's private partner-feed with the secret partner key
//      (FLIXVAULT_PARTNER_KEY, kept only here, never in the app), passing the
//      audience and Premium flag Puffle decided;
//   3. returns the result to the app.
//
// Secrets (Supabase → Edge Functions → Secrets):
//   FLIXVAULT_PARTNER_KEY   the key from Flixvault admin → "Share with Puffle"
//   FLIXVAULT_FEED_URL      Flixvault's feed address (or private.flixvault_settings)
//
// App request: POST JSON { action, ... }
//   explore   { tab?, offset?, search? }
//   channels  { sort?, search? }
//   channel   { channel_id, before? }
//   post      { post_id }
//   play      { item_id, kind: "video" | "preview" }
//   following { }            newest posts of the Flixvault channels the user follows
//
// Browsing uses Puffle's own copy of Flixvault (see flixvault-sync); only play
// calls Flixvault, so Puffle traffic barely touches Flixvault's database.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.8";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
// Flixvault's feed address: project secret FLIXVAULT_FEED_URL, else the
// private.flixvault_settings row (read with the service role, cached).
let feedUrl: string | null = Deno.env.get("FLIXVAULT_FEED_URL") || null;
async function feedAddress(): Promise<string> {
  if (feedUrl) return feedUrl;
  const svc = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data } = await svc.rpc("flixvault_feed_url");
  feedUrl = typeof data === "string" && data.startsWith("https://") ? data : null;
  return feedUrl ?? "";
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

type Status = { is_guest?: boolean; source?: string; has_ads_access?: boolean; can_play_premium?: boolean };

async function viewerId(uid: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("puffle:" + uid)));
  return Array.from(d.slice(0, 16), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function feed(body: Record<string, unknown>): Promise<{ status: number; data: any }> {
  const key = Deno.env.get("FLIXVAULT_PARTNER_KEY") ?? "";
  const FEED = await feedAddress();
  if (!key || !FEED) return { status: 503, data: { error: "not_configured" } };
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 15000);
  try {
    const res = await fetch(FEED, {
      method: "POST",
      headers: { "content-type": "application/json", "x-partner-key": key },
      body: JSON.stringify(body),
      signal: ctl.signal,
    });
    const data = await res.json().catch(() => ({ error: "bad_response" }));
    return { status: res.status, data };
  } catch {
    return { status: 502, data: { error: "unavailable" } };
  } finally {
    clearTimeout(timer);
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const sb = createClient(url, anon, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: who, error: whoError } = await sb.auth.getUser();
  if (whoError || !who.user) return json({ error: "not signed in" }, 401);

  const { data: st, error: stError } = await sb.rpc("my_status");
  if (stError || !st) return json({ error: "status unavailable" }, 503);
  const status = st as Status;
  // Same rule Puffle uses for its own content: ads access => ads content.
  const audience = status.has_ads_access ? "ads" : "organic";
  const premium = status.can_play_premium === true;

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid request body" }, 400);
  }
  const action = String(body.action ?? "");

  // Hide channels the user blocked (stored in Puffle).
  const blocked = async (): Promise<Set<string>> => {
    const { data } = await sb.from("flixvault_blocks").select("channel_id");
    return new Set((data ?? []).map((r: { channel_id: string }) => r.channel_id));
  };
  const dropBlocked = (posts: any[], b: Set<string>) => posts.filter((p) => !b.has(p?.channel_id));

  // Browsing reads Puffle's own copy (flixvault_* tables, refreshed by
  // flixvault-sync); the table policies apply the ads/organic rule. Only "play"
  // asks Flixvault, which checks the rules again and signs the video link.
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(fn, args);
    if (error) throw new Error(error.message);
    return data;
  };
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim().slice(0, 100) : null);
  const num = (v: unknown) => (Number.isFinite(Number(v)) ? Math.max(0, Math.trunc(Number(v))) : 0);
  const id = (v: unknown) => (typeof v === "string" && UUID.test(v) ? v : null);

  try {
  switch (action) {
    case "explore": {
      const tab = ["all", "latest", "popular", "most_watched"].includes(String(body.tab)) ? String(body.tab) : "all";
      const [posts, b] = await Promise.all([
        rpc("fv_explore", { p_tab: tab, p_offset: num(body.offset), p_limit: 30, p_search: str(body.search) }),
        blocked(),
      ]);
      return json({ posts: dropBlocked(posts ?? [], b) });
    }
    case "channels": {
      const sort = ["trending", "latest", "top"].includes(String(body.sort)) ? String(body.sort) : "trending";
      const [channels, b] = await Promise.all([rpc("fv_channels", { p_sort: sort, p_search: str(body.search) }), blocked()]);
      return json({ channels: (channels ?? []).filter((c: any) => !b.has(c?.id)) });
    }
    case "channel": {
      const cid = id(body.channel_id);
      if (!cid) return json({ error: "channel_id required" }, 400);
      const before = typeof body.before === "string" && !isNaN(Date.parse(body.before)) ? body.before : null;
      const data = await rpc("fv_channel", { p_channel_id: cid, p_before: before });
      return data ? json(data) : json({ error: "not found" }, 404);
    }
    case "post": {
      const pid = id(body.post_id);
      if (!pid) return json({ error: "post_id required" }, 400);
      const post = await rpc("fv_post", { p_post_id: pid });
      return post ? json({ post }) : json({ error: "not found" }, 404);
    }
    case "following": {
      return json({ posts: (await rpc("fv_following", {})) ?? [] });
    }
    case "play": {
      // Puffle's own rule: organic guests must log in before any media plays.
      if (status.is_guest && status.source !== "ads") return json({ error: "login_required" }, 403);
      const kind = body.kind === "preview" ? "preview" : "video";
      const r = await feed({
        action, audience, item_id: body.item_id, kind, premium, viewer: await viewerId(who.user.id),
      });
      return json(r.data, r.status);
    }
    default:
      return json({ error: "unknown action" }, 400);
  }
  } catch {
    return json({ error: "unavailable" }, 503);
  }
});
