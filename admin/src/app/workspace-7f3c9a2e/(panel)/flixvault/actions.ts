"use server";
import { requireAdmin, flash, str, UUID } from "@/lib/admin";

// Hide or show a copied Flixvault channel/post in the Puffle app only.
// Flixvault itself is never changed; the copy keeps this choice on every refresh.
export async function setFlixvaultHidden(fd: FormData) {
  const { sb } = await requireAdmin();
  const type = str(fd, "type"), id = str(fd, "id"), hidden = str(fd, "hidden") === "1";
  const back = str(fd, "back").startsWith("/workspace-7f3c9a2e/flixvault") ? str(fd, "back") : "/workspace-7f3c9a2e/flixvault";
  if (!UUID.test(id) || !["channel", "post"].includes(type)) flash(back, { message: "Choose a valid channel or post." }, "");
  const table = type === "channel" ? "flixvault_channels" : "flixvault_posts";
  const { data, error } = await sb.from(table).update({ hidden }).eq("id", id).select("id");
  flash(back, error ?? (!data?.length ? { message: "Not found." } : null), hidden ? "Hidden in the Puffle app." : "Visible in the Puffle app again.");
}
