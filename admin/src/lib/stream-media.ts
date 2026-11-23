import type { SupabaseClient } from "@supabase/supabase-js";

export const isBunnyKey = (key: string) => /^[0-9a-f-]{36}\/bunny\/[0-9a-f-]{36}$/.test(key);

export async function mediaUrls(sb: SupabaseClient, keys: string[], kind: "thumbnail" | "full" | "trailer") {
  const urls: Record<string, string> = {};
  const unique = [...new Set(keys)];
  const legacy = unique.filter(key => !isBunnyKey(key));
  const stream = unique.filter(isBunnyKey);
  if (legacy.length) {
    const { data, error } = await sb.storage.from("media").createSignedUrls(legacy, 3600);
    if (error && keys.length === 1) throw error;
    for (const entry of data ?? []) if (entry.path && entry.signedUrl) urls[entry.path] = entry.signedUrl;
  }
  for (let offset = 0; offset < stream.length; offset += 80) {
    const { data, error } = await sb.functions.invoke("bunny-stream", {
      body: { action: "urls", kind, keys: stream.slice(offset, offset + 80) },
    });
    if (error && keys.length === 1) throw error;
    Object.assign(urls, data?.urls ?? {});
  }
  return urls;
}
