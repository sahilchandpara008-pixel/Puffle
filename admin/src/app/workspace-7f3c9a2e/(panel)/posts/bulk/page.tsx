import { requireAdmin, allowedChannels } from "@/lib/admin";
import { PageHeader, LinkButton, ErrorNote } from "@/components/admin/ui";
import BulkUpload from "./BulkUpload";
import UploadModeNav from "../UploadModeNav";

export default async function BulkUploadPage({ searchParams }: { searchParams: { channel?: string } }) {
  const { sb, role, user } = await requireAdmin();
  const allowed = await allowedChannels(sb, role, user.id);
  let query = sb.from("channels").select("id,name,audience,review_status,status,hidden").order("name");
  if (allowed) query = query.in("id", allowed.length ? allowed : ["00000000-0000-0000-0000-000000000000"]);
  const { data, error } = await query;
  return <>
    <PageHeader title="Bulk upload" sub="Upload from this browser directly to a channel. Each file becomes a separate post.">
      <LinkButton href="/workspace-7f3c9a2e/posts">Back to posts</LinkButton>
    </PageHeader>
    <UploadModeNav active="bulk" />
    <ErrorNote error={error} />
    <BulkUpload channels={data ?? []} initialChannelId={searchParams.channel} />
  </>;
}
