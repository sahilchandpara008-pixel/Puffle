import { createClient } from "npm:@supabase/supabase-js@2.49.8";
import { bunnyObjectPath, readBunnyStorage, removeBunnyObject } from "../_shared/bunny-storage.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return Response.json({ error: "Method not allowed" }, { status: 405 });
  const { data: allowed } = await db.rpc("meta_cron_ok", { p_key: req.headers.get("x-cron-key") ?? "" });
  if (allowed !== true) return Response.json({ error: "Forbidden" }, { status: 403 });
  const config = readBunnyStorage((key) => Deno.env.get(key));
  if (!config) return Response.json({ status: "unconfigured" });
  const { data, error } = await db.rpc("next_bunny_cloud_cleanup");
  if (error) return Response.json({ error: "Could not load cleanup queue" }, { status: 503 });

  const results = await Promise.allSettled((data ?? []).map(async (file: {
    user_id: string; file_id: string; staging_path: string;
  }) => {
    await removeBunnyObject(config, bunnyObjectPath(file.user_id, file.file_id));
    const { error: stagingError } = await db.storage.from("cloud").remove([file.staging_path]);
    if (stagingError) throw new Error("Could not remove staging object");
    const { error: finishError } = await db.rpc("finish_bunny_cloud_cleanup", { p_file: file.file_id });
    if (finishError) throw new Error("Could not finish cleanup");
  }));
  return Response.json({ removed: results.filter((result) => result.status === "fulfilled").length,
    retry: results.filter((result) => result.status === "rejected").length });
});
