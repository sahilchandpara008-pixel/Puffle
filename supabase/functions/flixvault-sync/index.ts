// Copies Flixvault's channels and posts into Puffle's own flixvault_* tables.
// Run every 10 minutes by pg_cron (x-cron-key, like Puffle's other jobs).
//
// Read-only towards Flixvault: it only READS the partner feed. It never stores
// Flixvault video ids and never writes anything to Flixvault. If Flixvault
// can't be reached or sharing is off, Puffle's copy is left unchanged.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.8";

const FEED = Deno.env.get("FLIXVAULT_FEED_URL") ??
  "https://lcfiohprmviolzwglkhm.supabase.co/functions/v1/partner-feed";
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });

async function feed(body: Record<string, unknown>): Promise<any> {
  const key = Deno.env.get("FLIXVAULT_PARTNER_KEY") ?? "";
  if (!key) throw new Error("FLIXVAULT_PARTNER_KEY not set");
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 20000);
  try {
    const r = await fetch(FEED, {
      method: "POST", signal: ctl.signal,
      headers: { "content-type": "application/json", "x-partner-key": key },
      body: JSON.stringify(body),
    });
    if (r.status !== 200) throw new Error(`feed ${body.action} ${body.audience}: HTTP ${r.status}`);
    return await r.json();
  } finally {
    clearTimeout(t);
  }
}

async function allPosts(audience: string): Promise<any[]> {
  const out: any[] = [];
  for (let offset = 0; offset < 5000; offset += 100) {
    const page = (await feed({ action: "explore", audience, tab: "latest", limit: 100, offset })).posts ?? [];
    out.push(...page);
    if (page.length < 100) break;
  }
  return out;
}

// In both lists => 'all'; only in one => that audience.
function withAudience(ads: any[], organic: any[]) {
  const a = new Map(ads.map((x) => [x.id, x]));
  const o = new Map(organic.map((x) => [x.id, x]));
  const out: any[] = [];
  for (const [id, x] of a) out.push({ ...x, audience: o.has(id) ? "all" : "ads" });
  for (const [id, x] of o) if (!a.has(id)) out.push({ ...x, audience: "organic" });
  return out;
}

Deno.serve(async (req) => {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: ok } = await db.rpc("meta_cron_ok", { p_key: req.headers.get("x-cron-key") ?? "" });
  if (ok !== true) return json({ error: "unauthorized" }, 401);
  try {
    const [chAds, chOrg, poAds, poOrg] = await Promise.all([
      feed({ action: "channels", audience: "ads" }).then((r) => r.channels ?? []),
      feed({ action: "channels", audience: "organic" }).then((r) => r.channels ?? []),
      allPosts("ads"),
      allPosts("organic"),
    ]);
    const channels = withAudience(chAds, chOrg);
    const posts = withAudience(poAds, poOrg);
    const { data, error } = await db.rpc("flixvault_apply", { p: { channels, posts } });
    if (error) throw new Error(error.message);
    return json(data);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.rpc("flixvault_sync_failed", { p_error: msg });
    return json({ error: msg }, 502);
  }
});
