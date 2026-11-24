import { requireAdmin } from "@/lib/admin";
import { ist } from "@/lib/format";
import { PageHeader, Card, Table, Th, Td, Empty, Badge, Hidden, Input, Select, Textarea, Field, Stat, ErrorNote } from "@/components/admin/ui";
import { SubmitButton } from "@/components/admin/client";
import { sendPush, cancelPush, savePushSettings } from "./actions";

type Msg = { id: string; title: string; body: string | null; type: string; audience: string; status: string; scheduled_at: string;
  auto: boolean; created_at: string; recipients: number; sent: number; failed: number; opened: number };
type Overview = { settings: { auto_enabled: boolean; quiet_start: number; quiet_end: number; daily_cap: number };
  phones: number; users: number; messages: Msg[] };

const AUD: Record<string, string> = { all: "Everyone", ads: "Ads users", organic: "Organic users", premium: "Premium users", free: "Free users" };
const hours = Array.from({ length: 24 }, (_, h) => h);
const hh = (h: number) => `${String(h).padStart(2, "0")}:00`;

async function firebaseStatus(): Promise<{ key: boolean; login?: string } | null> {
  try {
    const r = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/push-send?check=1`, { cache: "no-store" });
    return await r.json();
  } catch { return null; }
}

export default async function Notifications() {
  const { sb } = await requireAdmin(true);
  const [{ data, error }, fb, { data: posts }] = await Promise.all([
    sb.rpc("admin_push_overview"),
    firebaseStatus(),
    sb.from("flixvault_posts").select("id,title").order("published_at", { ascending: false }).limit(100),
  ]);
  const o = (data ?? null) as Overview | null;
  const s = o?.settings;
  return (
    <>
      <PageHeader title="Notifications" sub="Send messages to Puffle phones, or let Puffle announce new videos automatically." />
      <ErrorNote error={error} />
      <div className="mb-5 grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Phones that can receive" value={o?.phones ?? 0} />
        <Stat label="Users" value={o?.users ?? 0} />
        <Stat label="Automation" value={s?.auto_enabled ? "On" : "Off"} />
        <Stat label="Firebase key" value={fb?.key ? (fb.login === "ok" ? "Working" : "Check key") : "Not set"} tone={fb?.key && fb.login === "ok" ? undefined : "warn"} />
      </div>
      {!fb?.key && (
        <Card className="mb-5"><p className="text-sm text-amber-700">Add the Firebase service-account key in Supabase → Edge Functions → Secrets as <code>FCM_SERVICE_ACCOUNT</code>. Until then messages are kept but not delivered.</p></Card>
      )}

      <div className="mb-6 grid gap-5 lg:grid-cols-2">
        <Card title="Send a message">
          <form action={sendPush} className="mt-3 space-y-3">
            <Field label="Title"><Input name="title" maxLength={80} required placeholder="New videos are waiting" /></Field>
            <Field label="Message (optional)"><Textarea name="body" maxLength={240} rows={2} /></Field>
            <Field label="Picture link (optional)" hint="https:// image shown in the notification"><Input name="image" placeholder="https://…" /></Field>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Send to">
                <Select name="audience" defaultValue="all">{Object.entries(AUD).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>
              </Field>
              <Field label="When tapped, open">
                <Select name="type" defaultValue="none">
                  <option value="none">The app</option><option value="post">A video</option><option value="premium">Premium page</option><option value="url">A web link</option>
                </Select>
              </Field>
            </div>
            <Field label="Video (if “A video”)">
              <Select name="target" defaultValue=""><option value="">—</option>{(posts ?? []).map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}</Select>
            </Field>
            <Field label="Web link (if “A web link”)"><Input name="url" placeholder="https://…" /></Field>
            <Field label="Schedule (India time, optional)" hint="Leave empty to send now"><Input type="datetime-local" name="when" /></Field>
            <SubmitButton confirm="Send this notification?">Send</SubmitButton>
          </form>
        </Card>

        <Card title="Automation" sub="Announce each new Flixvault video in Puffle to the users allowed to see it (ads/organic rules).">
          <form action={savePushSettings} className="mt-3 space-y-3">
            <Field label="Automatic new-video notifications">
              <Select name="auto" defaultValue={s?.auto_enabled ? "1" : "0"}><option value="1">On</option><option value="0">Off</option></Select>
            </Field>
            <div className="grid gap-3 sm:grid-cols-3">
              <Field label="Quiet from (IST)"><Select name="quiet_start" defaultValue={String(s?.quiet_start ?? 23)}>{hours.map((h) => <option key={h} value={h}>{hh(h)}</option>)}</Select></Field>
              <Field label="Quiet until (IST)"><Select name="quiet_end" defaultValue={String(s?.quiet_end ?? 9)}>{hours.map((h) => <option key={h} value={h}>{hh(h)}</option>)}</Select></Field>
              <Field label="Max per day"><Select name="daily_cap" defaultValue={String(s?.daily_cap ?? 2)}>{[0, 1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{n}</option>)}</Select></Field>
            </div>
            <p className="text-xs text-gray-500">No messages are sent in quiet hours. Turning this on never announces videos that already exist.</p>
            <SubmitButton>Save</SubmitButton>
          </form>
        </Card>
      </div>

      <h2 className="mb-2 text-sm font-semibold text-gray-900">Recent messages</h2>
      {(o?.messages ?? []).length === 0 ? <Empty>No notifications yet.</Empty> : (
        <Table min={820}>
          <thead><tr><Th>Message</Th><Th>To</Th><Th>Status</Th><Th>Phones</Th><Th>Delivered</Th><Th>Tapped</Th><Th>When</Th><Th></Th></tr></thead>
          <tbody>
            {(o?.messages ?? []).map((m) => (
              <tr key={m.id}>
                <Td><div className="font-medium text-gray-900">{m.title}</div>{m.body && <div className="text-xs text-gray-500">{m.body}</div>}{m.auto && <div className="mt-1"><Badge tone="blue">Automatic</Badge></div>}</Td>
                <Td>{AUD[m.audience] ?? m.audience}</Td>
                <Td><Badge tone={m.status === "sent" ? "green" : m.status === "cancelled" ? "gray" : "amber"}>{m.status}</Badge></Td>
                <Td>{m.recipients}</Td>
                <Td>{m.sent}{m.failed ? <span className="text-xs text-red-600"> · {m.failed} failed</span> : null}</Td>
                <Td>{m.opened}</Td>
                <Td className="whitespace-nowrap text-xs text-gray-500">{ist(m.status === "queued" ? m.scheduled_at : m.created_at)}</Td>
                <Td>{m.status === "queued" && (
                  <form action={cancelPush}><Hidden name="id" value={m.id} /><SubmitButton variant="danger" small confirm="Cancel this notification?">Cancel</SubmitButton></form>
                )}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      )}
    </>
  );
}
