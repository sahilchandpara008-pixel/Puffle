import { Tabs } from "@/components/admin/ui";

const items = [
  { key: "single", label: "Single post", href: "/workspace-7f3c9a2e/posts/new" },
  { key: "bulk", label: "Bulk upload", href: "/workspace-7f3c9a2e/posts/bulk" },
];

export default function UploadModeNav({ active }: { active: "single" | "bulk" }) {
  return <nav aria-label="Upload mode"><Tabs items={items} current={active} /></nav>;
}
