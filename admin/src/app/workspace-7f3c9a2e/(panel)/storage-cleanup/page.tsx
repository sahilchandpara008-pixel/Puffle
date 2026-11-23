import { requireAdmin } from "@/lib/admin";
import { PageHeader } from "@/components/admin/ui";
import StorageCleanup from "./StorageCleanup";

export default async function Page() {
  await requireAdmin(true);
  return <>
    <PageHeader title="Storage cleanup" sub="Review unused Bunny Stream videos before permanently deleting them." />
    <StorageCleanup />
  </>;
}
