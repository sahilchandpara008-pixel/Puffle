"use server";
import { requireAdmin, flash, str, UUID } from "@/lib/admin";

const BACK = "/workspace-7f3c9a2e/notifications";
const istToUtc = (local: string) => (local ? new Date(local + ":00+05:30").toISOString() : null);

export async function sendPush(fd: FormData) {
  const { sb } = await requireAdmin(true);
  const title = str(fd, "title"), type = str(fd, "type") || "none", target = str(fd, "target"), url = str(fd, "url");
  if (!title) flash(BACK, { message: "Write a title." }, "");
  if ((type === "post" || type === "channel") && !UUID.test(target)) flash(BACK, { message: "Choose the video or channel to open." }, "");
  if (type === "url" && !url.startsWith("https://")) flash(BACK, { message: "The link must start with https://" }, "");
  const when = istToUtc(str(fd, "when"));
  const { error } = await sb.rpc("admin_push_create", {
    p_title: title, p_body: str(fd, "body"), p_image: str(fd, "image"), p_type: type,
    p_target: target, p_url: url, p_audience: str(fd, "audience") || "all", p_scheduled_at: when,
  });
  flash(BACK, error, when ? "Scheduled." : "Queued. It goes out within a minute.");
}

export async function cancelPush(fd: FormData) {
  const { sb } = await requireAdmin(true);
  const { error } = await sb.rpc("admin_push_cancel", { p_id: str(fd, "id") });
  flash(BACK, error, "Cancelled.");
}

export async function savePushSettings(fd: FormData) {
  const { sb } = await requireAdmin(true);
  const { error } = await sb.rpc("admin_push_settings_save", {
    p_auto: str(fd, "auto") === "1",
    p_quiet_start: Number(str(fd, "quiet_start")), p_quiet_end: Number(str(fd, "quiet_end")),
    p_daily_cap: Number(str(fd, "daily_cap")),
  });
  flash(BACK, error, "Automation saved.");
}

export async function saveAuto(fd: FormData) {
  const { sb } = await requireAdmin(true);
  const { error } = await sb.rpc("admin_push_auto_save", {
    p_kind: str(fd, "kind"), p_enabled: str(fd, "enabled") === "1",
    p_title: str(fd, "title"), p_body: str(fd, "body"),
    p_title2: str(fd, "title2") || null, p_body2: str(fd, "body2") || null,
  });
  flash(BACK, error, "Automatic message saved.");
}

export async function saveDaily(fd: FormData) {
  const { sb } = await requireAdmin(true);
  const hours = fd.getAll("hours").map((h) => Number(h)).filter((h) => Number.isInteger(h) && h >= 0 && h <= 23);
  const msgs = fd.getAll("pos").map((p) => ({
    pos: Number(p), title: str(fd, `title_${p}`), body: str(fd, `body_${p}`), enabled: str(fd, `on_${p}`) === "1",
  }));
  const { error } = await sb.rpc("admin_push_daily_save", { p_hours: hours, p_msgs: msgs });
  flash(BACK, error, "Daily messages saved.");
}
