import { Upload } from "tus-js-client";
import type { SupabaseClient } from "@supabase/supabase-js";

export async function uploadStream(
  sb: SupabaseClient, path: string, file: Blob, contentType: string,
  onProgress: (percent: number) => void, purpose: "main" | "trailer",
) {
  if (!contentType.startsWith("video/")) return null;
  const channel = path.split("/")[0];
  const title = file instanceof File ? file.name : "Puffle video";
  const lastModified = file instanceof File ? file.lastModified : 0;
  const user = (await sb.auth.getSession()).data.session?.user.id;
  if (!user) throw new Error("Your session expired. Sign in again.");
  const fingerprint = JSON.stringify(["puffle-stream", user, channel, purpose, title, contentType, file.size, lastModified]);
  const cached = localStorage.getItem(fingerprint);
  const requestGrant = (resumeId?: string) => sb.functions.invoke("bunny-stream", {
    body: { action: "create", channel_id: channel, title, content_type: contentType, purpose, resume_id: resumeId },
  });
  let grant = await requestGrant(cached ?? undefined);
  if (cached && grant.error && grant.error.context?.status === 409) {
    localStorage.removeItem(fingerprint);
    grant = await requestGrant();
  }
  if (grant.error) throw new Error("Could not authorize the video upload. Please try again.");
  if (grant.data?.configured === false) return null;
  const { id, key, headers } = grant.data;
  localStorage.setItem(fingerprint, id);
  await new Promise<void>((resolve, reject) => {
    const upload = new Upload(file, {
      endpoint: "https://video.bunnycdn.com/tusupload", headers, chunkSize: 32 * 1024 * 1024,
      retryDelays: [0, 1000, 3000, 6000, 12000], removeFingerprintOnSuccess: true,
      fingerprint: async () => `${fingerprint}:${id}`,
      metadata: { title, filetype: contentType },
      onBeforeRequest: (request) => {
        const url = new URL(request.getURL());
        if (url.origin !== "https://video.bunnycdn.com") throw new Error("Invalid Bunny upload destination.");
      },
      onProgress: (sent, size) => onProgress(Math.round((sent / size) * 100)),
      onError: () => reject(new Error("Video upload was interrupted. Retry to resume.")),
      onSuccess: () => resolve(),
    });
    void upload.findPreviousUploads().then(([previous]) => {
      if (previous && cached === id) upload.resumeFromPreviousUpload(previous);
      upload.start();
    }).catch(reject);
  });
  localStorage.removeItem(fingerprint);
  return key as string;
}
