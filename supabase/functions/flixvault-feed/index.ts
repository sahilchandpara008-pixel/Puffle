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
//   FLIXVAULT_FEED_URL      optional; defaults to Flixvault's partner-feed URL
//
// App request: POST JSON { action, ... }
//   explore   { tab?, offset?, search? }
//   channels  { sort?, search? }
//   channel   { channel_id, before? }
//   post      { post_id }
//   play      { item_id, kind: "video" | "preview" }
//   following { }            newest posts of the Flixvault channels the user follows
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.8";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const FEED = Deno.env.get("FLIXVAULT_FEED_URL") ??
  "https://lcfiohprmviolzwglkhm.supabase.co/functions/v1/partner-feed";

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
  if (!key) return { status: 503, data: { error: "not_configured" } };
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

  switch (action) {
    case "explore": {
      const [r, b] = await Promise.all([
        feed({ action, audience, tab: body.tab, offset: body.offset, limit: 30, search: body.search }),
        blocked(),
      ]);
      if (r.status !== 200) return json(r.data, r.status);
      return json({ posts: dropBlocked(r.data.posts ?? [], b) });
    }
    case "channels": {
      const [r, b] = await Promise.all([feed({ action, audience, sort: body.sort, search: body.search }), blocked()]);
      if (r.status !== 200) return json(r.data, r.status);
      return json({ channels: (r.data.channels ?? []).filter((c: any) => !b.has(c?.id)) });
    }
    case "channel": {
      const r = await feed({ action, audience, channel_id: body.channel_id, before: body.before });
      return json(r.data, r.status);
    }
    case "post": {
      const r = await feed({ action, audience, post_id: body.post_id });
      return json(r.data, r.status);
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
    case "following": {
      const { data: rows } = await sb.from("flixvault_follows").select("channel_id")
        .order("created_at", { ascending: false }).limit(20);
      const ids = (rows ?? []).map((r: { channel_id: string }) => r.channel_id).filter((id: string) => UUID.test(id));
      if (ids.length === 0) return json({ posts: [] });
      const pages = await Promise.all(ids.map((id: string) => feed({ action: "channel", audience, channel_id: id })));
      const posts = pages.filter((p) => p.status === 200).flatMap((p) => p.data.posts ?? []);
      posts.sort((a: any, b: any) => String(b.published_at).localeCompare(String(a.published_at)));
      return json({ posts: dropBlocked(posts, await blocked()).slice(0, 100) });
    }
    default:
      return json({ error: "unknown action" }, 400);
  }
});
