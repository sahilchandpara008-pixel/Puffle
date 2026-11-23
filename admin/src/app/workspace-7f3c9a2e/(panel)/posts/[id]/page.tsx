import { notFound } from "next/navigation";
import { requireAdmin } from "@/lib/admin";
import { mediaUrls } from "@/lib/stream-media";
import { PageHeader, Card, LinkButton, Hidden, StatusBadge, Badge } from "@/components/admin/ui";
import { SubmitButton } from "@/components/admin/client";
import { savePost, deletePost, setHidden } from "../../actions";
import PostFields from "../PostFields";
import MediaEditor, { type Item } from "./MediaEditor";

export default async function PostEdit({ params }: { params: { id: string } }) {
  const { sb, role } = await requireAdmin();
  const { data: p } = await sb.from("posts").select("*, channels(name)").eq("id", params.id).maybeSingle();
  if (!p) notFound();
  const { data: can } = await sb.rpc("can_edit_post", { p_post: params.id });
  if (!can) notFound();
  const { data: items } = await sb.from("post_items").select("*").eq("post_id", params.id).order("position");
  const keys = (items ?? []).map((i) => i.thumbnail_key).filter(Boolean) as string[];
  const thumbs = await mediaUrls(sb, keys, "thumbnail").catch(() => ({} as Record<string, string>));
  const ch = p.channels as { name?: string } | null;
  return (
    <>
      <PageHeader title={p.title} sub={`In ${ch?.name ?? "channel"}`}>
        <StatusBadge value={p.status} />{p.hidden && <Badge tone="red">Hidden</Badge>}
        <LinkButton href="/workspace-7f3c9a2e/posts">Back to posts</LinkButton>
      </PageHeader>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Details">
          <form action={savePost} className="space-y-3">
            <Hidden name="id" value={p.id} />
            <PostFields p={p} />
            <SubmitButton>Save post</SubmitButton>
          </form>
        </Card>
        <Card title="Media" sub="The main video or image, an optional trailer for non-premium viewers, and a thumbnail.">
          <MediaEditor postId={p.id} channelId={p.channel_id} items={(items ?? []) as Item[]} thumbs={thumbs} />
        </Card>
      </div>
      <Card title="Danger zone" className="mt-4">
        <div className="flex flex-wrap gap-2">
          {role === "owner" && (
            <form action={setHidden}>
              <Hidden name="type" value="post" /><Hidden name="id" value={p.id} /><Hidden name="hidden" value={p.hidden ? "0" : "1"} /><Hidden name="back" value={`/workspace-7f3c9a2e/posts/${p.id}`} />
              <SubmitButton variant="secondary" confirm={p.hidden ? undefined : "Hide this post from the app?"}>{p.hidden ? "Unhide post" : "Hide post"}</SubmitButton>
            </form>
          )}
          <form action={deletePost}>
            <Hidden name="id" value={p.id} />
            <SubmitButton variant="danger" confirm="Delete this post and all its video files? This cannot be undone.">Delete post</SubmitButton>
          </form>
        </div>
      </Card>
    </>
  );
}
