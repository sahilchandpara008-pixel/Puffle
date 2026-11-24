import { requireAdmin } from "@/lib/admin";
import { ist } from "@/lib/format";
import { PageHeader, Card, Table, Th, Td, Empty, AudienceBadge, Badge, Hidden, Input, Button, Stat, Tabs, ErrorNote } from "@/components/admin/ui";
import { SubmitButton } from "@/components/admin/client";
import { setFlixvaultHidden } from "./actions";

type Q = { tab?: string; q?: string };
const BASE = "/workspace-7f3c9a2e/flixvault";

type Sync = { last_run: string | null; last_ok: string | null; channels: number | null; posts: number | null; error: string | null;
  hidden_channels: number; hidden_posts: number; follows: number; reports_7d: number };

function HideForm({ type, id, hidden, back }: { type: "channel" | "post"; id: string; hidden: boolean; back: string }) {
  return (
    <form action={setFlixvaultHidden}>
      <Hidden name="type" value={type} /><Hidden name="id" value={id} /><Hidden name="hidden" value={hidden ? "0" : "1"} /><Hidden name="back" value={back} />
      <SubmitButton variant={hidden ? "success" : "danger"} confirm={hidden ? undefined : `Hide this ${type} in the Puffle app? Flixvault is not changed.`}>{hidden ? "Show" : "Hide"}</SubmitButton>
    </form>
  );
}

export default async function FlixvaultContent({ searchParams }: { searchParams: Q }) {
  const { sb } = await requireAdmin();
  const tab = ["channels", "posts", "reports"].includes(searchParams.tab ?? "") ? searchParams.tab! : "channels";
  const term = (searchParams.q ?? "").trim().replace(/[%_,()]/g, " ").trim();
  const back = `${BASE}?tab=${tab}${term ? `&q=${encodeURIComponent(term)}` : ""}`;

  const { data: syncData, error: syncError } = await sb.rpc("admin_flixvault_sync");
  const sync = (syncData ?? null) as Sync | null;

  let body: React.ReactNode = null;
  let error: { message: string } | null = syncError;

  if (tab === "channels") {
    let q = sb.from("flixvault_channels").select("id,name,category,audience,members_count,icon_url,hidden,created_at").order("members_count", { ascending: false }).limit(300);
    if (term) q = q.ilike("name", `%${term}%`);
    const [{ data: rows, error: e1 }, { data: stats }] = await Promise.all([q, sb.rpc("admin_flixvault_channel_stats")]);
    error = error ?? e1;
    const byId = new Map(((stats ?? []) as { channel_id: string; follows: number; blocks: number; reports: number }[]).map((s) => [s.channel_id, s]));
    body = (rows ?? []).length === 0 ? <Empty>No Flixvault channels copied yet.</Empty> : (
      <Table min={820}>
        <thead><tr><Th>Channel</Th><Th>Category</Th><Th>Audience</Th><Th>Flixvault followers</Th><Th>Puffle follows</Th><Th>Blocked by</Th><Th>Reports</Th><Th></Th></tr></thead>
        <tbody>
          {(rows ?? []).map((c) => {
            const s = byId.get(c.id);
            return (
              <tr key={c.id}>
                <Td>
                  <div className="flex items-center gap-2 font-medium text-gray-900">
                    {c.icon_url
                      // eslint-disable-next-line @next/next/no-img-element
                      ? <img src={c.icon_url} alt="" className="h-8 w-8 shrink-0 rounded-lg object-cover" />
                      : <span className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-violet-100 text-sm font-bold text-violet-700">{c.name.charAt(0).toUpperCase()}</span>}
                    {c.name}
                  </div>
                  {c.hidden && <div className="mt-1"><Badge tone="red">Hidden in Puffle</Badge></div>}
                </Td>
                <Td>{c.category ?? "—"}</Td>
                <Td><AudienceBadge value={c.audience} /></Td>
                <Td>{c.members_count}</Td>
                <Td>{s?.follows ?? 0}</Td>
                <Td>{s?.blocks ?? 0}</Td>
                <Td>{s?.reports ? <Badge tone="amber">{s.reports}</Badge> : 0}</Td>
                <Td><HideForm type="channel" id={c.id} hidden={c.hidden} back={back} /></Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    );
  } else if (tab === "posts") {
    let q = sb.from("flixvault_posts").select("id,title,audience,published_at,view_count,hidden,flixvault_channels(name),flixvault_items(thumb_url,is_premium,position)").order("published_at", { ascending: false }).limit(300);
    if (term) q = q.ilike("title", `%${term}%`);
    const { data: rows, error: e1 } = await q;
    error = error ?? e1;
    body = (rows ?? []).length === 0 ? <Empty>No Flixvault posts match.</Empty> : (
      <Table min={760}>
        <thead><tr><Th></Th><Th>Title</Th><Th>Channel</Th><Th>Audience</Th><Th>Premium</Th><Th>Flixvault views</Th><Th>Published</Th><Th></Th></tr></thead>
        <tbody>
          {(rows ?? []).map((p) => {
            const items = (p.flixvault_items ?? []) as { thumb_url: string | null; is_premium: boolean; position: number }[];
            const thumb = [...items].sort((a, b) => a.position - b.position).find((i) => i.thumb_url)?.thumb_url;
            const ch = p.flixvault_channels as unknown as { name?: string } | { name?: string }[] | null;
            return (
              <tr key={p.id}>
                <Td className="w-20">
                  <div className="grid h-12 w-20 place-items-center overflow-hidden rounded-md bg-gray-100 text-[10px] text-gray-400">
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    {thumb ? <img src={thumb} alt="" className="h-full w-full object-cover" /> : "No image"}
                  </div>
                </Td>
                <Td><span className="font-medium text-gray-900">{p.title}</span>{p.hidden && <div className="mt-1"><Badge tone="red">Hidden in Puffle</Badge></div>}</Td>
                <Td>{(Array.isArray(ch) ? ch[0]?.name : ch?.name) ?? "—"}</Td>
                <Td><AudienceBadge value={p.audience} /></Td>
                <Td>{items.some((i) => i.is_premium) ? <Badge tone="amber">Premium</Badge> : <span className="text-gray-400">Free</span>}</Td>
                <Td>{p.view_count}</Td>
                <Td className="whitespace-nowrap text-xs text-gray-500">{ist(p.published_at)}</Td>
                <Td><HideForm type="post" id={p.id} hidden={p.hidden} back={back} /></Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    );
  } else {
    const { data: rows, error: e1 } = await sb.from("flixvault_reports").select("id,post_id,reason,created_at").order("created_at", { ascending: false }).limit(300);
    error = error ?? e1;
    const ids = [...new Set((rows ?? []).map((r) => r.post_id))];
    const { data: posts } = ids.length
      ? await sb.from("flixvault_posts").select("id,title,hidden,flixvault_channels(name)").in("id", ids)
      : { data: [] as { id: string; title: string; hidden: boolean; flixvault_channels: unknown }[] };
    const byId = new Map((posts ?? []).map((p) => [p.id, p]));
    body = (rows ?? []).length === 0 ? <Empty>No reports from Puffle users.</Empty> : (
      <Table min={720}>
        <thead><tr><Th>Post</Th><Th>Channel</Th><Th>Reason</Th><Th>Reported</Th><Th></Th></tr></thead>
        <tbody>
          {(rows ?? []).map((r) => {
            const p = byId.get(r.post_id);
            const ch = p?.flixvault_channels as { name?: string } | { name?: string }[] | null | undefined;
            return (
              <tr key={r.id}>
                <Td>{p ? <span className="font-medium text-gray-900">{p.title}</span> : <span className="text-gray-400">No longer on Flixvault</span>}{p?.hidden && <div className="mt-1"><Badge tone="red">Hidden in Puffle</Badge></div>}</Td>
                <Td>{(Array.isArray(ch) ? ch[0]?.name : ch?.name) ?? "—"}</Td>
                <Td><Badge tone="amber">{r.reason}</Badge></Td>
                <Td className="whitespace-nowrap text-xs text-gray-500">{ist(r.created_at)}</Td>
                <Td>{p && <HideForm type="post" id={p.id} hidden={p.hidden} back={back} />}</Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    );
  }

  return (
    <>
      <PageHeader title="Flixvault content" sub="Channels and videos copied from Flixvault every 10 minutes, with the same ads/organic rules. Hiding here only hides it in Puffle." />
      <ErrorNote error={error} />
      <div className="mb-5 grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Channels copied" value={sync?.channels ?? 0} />
        <Stat label="Posts copied" value={sync?.posts ?? 0} />
        <Stat label="Last copy" value={sync?.last_ok ? ist(sync.last_ok) : "Not yet"} tone={sync?.error ? "warn" : undefined} />
        <Stat label="Reports (7 days)" value={sync?.reports_7d ?? 0} tone={sync?.reports_7d ? "warn" : undefined} />
      </div>
      {sync?.error && (
        <Card className="mb-5"><p className="text-sm text-amber-700">Last copy attempt had a problem: {sync.error}. Puffle keeps showing the previous copy.</p></Card>
      )}
      <Tabs current={tab} items={[
        { key: "channels", label: "Channels", href: `${BASE}?tab=channels` },
        { key: "posts", label: "Posts", href: `${BASE}?tab=posts` },
        { key: "reports", label: "Reports", href: `${BASE}?tab=reports`, count: sync?.reports_7d || undefined },
      ]} />
      {tab !== "reports" && (
        <form className="mb-4 flex gap-2">
          <Hidden name="tab" value={tab} />
          <Input name="q" defaultValue={term} placeholder={tab === "channels" ? "Search channel" : "Search title"} aria-label="Search" />
          <Button variant="secondary">Search</Button>
        </form>
      )}
      {body}
    </>
  );
}
