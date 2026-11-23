export const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export const streamKey = /^[a-f0-9-]{36}\/bunny\/([a-f0-9-]{36})$/;
const encoder = new TextEncoder();

export function streamConfig(env: (key: string) => string | undefined) {
  const library = env("BUNNY_STREAM_LIBRARY_ID")?.trim();
  const apiKey = env("BUNNY_STREAM_API_KEY")?.trim();
  const host = env("BUNNY_STREAM_CDN_HOST")?.trim();
  const cdnKey = env("BUNNY_STREAM_TOKEN_KEY")?.trim();
  if (!library || !apiKey || !host || !cdnKey) return null;
  if (!/^\d+$/.test(library) || !/^[a-z\d-]+\.b-cdn\.net$/i.test(host)) {
    throw new Error("Invalid Bunny Stream configuration");
  }
  return { library, apiKey, origin: `https://${host}`, cdnKey };
}
export type StreamConfig = NonNullable<ReturnType<typeof streamConfig>>;

export async function streamApi(config: StreamConfig, path: string, init: RequestInit = {}) {
  return await fetch(`https://video.bunnycdn.com/library/${config.library}/videos${path}`, {
    ...init,
    headers: { AccessKey: config.apiKey, Accept: "application/json", "Content-Type": "application/json" },
    redirect: "error",
    signal: AbortSignal.timeout(8000),
  });
}

export async function tusAuthorization(config: StreamConfig, video: string, expiry: number) {
  const digest = await crypto.subtle.digest("SHA-256",
    encoder.encode(`${config.library}${config.apiKey}${expiry}${video}`));
  return {
    AuthorizationSignature: [...new Uint8Array(digest)].map((value) => value.toString(16).padStart(2, "0")).join(""),
    AuthorizationExpire: String(expiry), LibraryId: config.library, VideoId: video,
  };
}

export async function hmac(key: string, message: string) {
  const material = await crypto.subtle.importKey("raw", encoder.encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = await crypto.subtle.sign("HMAC", material, encoder.encode(message));
  return btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function bunnyCdnUrl(config: StreamConfig, path: string, expiry: number, directory = "") {
  const scope = directory || path;
  const parameters = directory ? `token_path=${directory}` : "";
  const token = `HS256-${await hmac(config.cdnKey, `${scope}${expiry}${parameters}`)}`;
  if (directory) {
    return `${config.origin}/bcdn_token=${token}&token_path=${encodeURIComponent(directory)}&expires=${expiry}${path}`;
  }
  return `${config.origin}${path}?token=${token}&expires=${expiry}`;
}

export function encodeState(status: number) {
  if (status === 3 || status === 4) return "ready";
  if ([5, 8].includes(status)) return "failed";
  return status === 0 || status === 6 ? "waiting" : "processing";
}

function resolveAsset(origin: string, playlist: string, directory: string, child: string) {
  const url = new URL(child, origin + playlist);
  if (url.origin !== origin || !url.pathname.startsWith(directory) || url.search || url.hash ||
      !/^[a-zA-Z0-9_./-]+$/.test(url.pathname)) throw new Error("Unexpected playlist item");
  return url.pathname;
}

// Generate a finite HLS media playlist whose URLs authorize one asset each.
// Byte ranges are rejected because signing their shared object would expose later segments.
export async function cutPreview(
  config: StreamConfig, playlist: string, directory: string, content: string, expiry: number,
) {
  const segments: Array<{ duration: string; path: string }> = [];
  const headers = ["#EXTM3U", "#EXT-X-PLAYLIST-TYPE:VOD"];
  let duration: string | null = null;
  let seconds = 0;
  for (const raw of content.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line === "#EXTM3U") continue;
    if (/^#EXT-X-(BYTERANGE|KEY|DISCONTINUITY|PART|SKIP|STREAM-INF|MEDIA:)/.test(line)) {
      throw new Error("Unsupported format for automatic preview");
    }
    if (/^#EXT-X-(VERSION|TARGETDURATION|MEDIA-SEQUENCE):\d+$/.test(line)) headers.push(line);
    if (line.startsWith("#EXT-X-MAP:")) {
      const match = /^#EXT-X-MAP:URI="([^"]+)"$/.exec(line);
      if (!match) throw new Error("Unsupported preview map");
      const path = resolveAsset(config.origin, playlist, directory, match[1]);
      if (!/\/[^/]+\.mp4$/.test(path)) throw new Error("Invalid preview map");
      headers.push(`#EXT-X-MAP:URI="${await bunnyCdnUrl(config, path, expiry)}"`);
    }
    if (line.startsWith("#EXTINF:")) {
      duration = /^#EXTINF:(\d+(?:\.\d+)?),/.exec(line)?.[1] ?? null;
    }
    if (!line.startsWith("#")) {
      const interval = Number(duration);
      if (!(interval > 0)) throw new Error("Invalid segment duration");
      if (seconds + interval > 120) break;
      const path = resolveAsset(config.origin, playlist, directory, line);
      if (!/\.(ts|m4s)$/.test(path)) throw new Error("Invalid preview segment");
      segments.push({ duration: duration!, path });
      seconds += interval;
      duration = null;
    }
  }
  if (!segments.length) throw new Error("Preview unavailable");
  const links = await Promise.all(segments.map(async (segment) =>
    `#EXTINF:${segment.duration},\n${await bunnyCdnUrl(config, segment.path, expiry)}`));
  return [...headers, ...links, "#EXT-X-ENDLIST", ""].join("\n");
}

export async function previewPlaylist(config: StreamConfig, id: string, expiry: number) {
  const directory = `/${id}/`;
  const master = directory + "playlist.m3u8";
  async function get(path: string) {
    const response = await fetch(await bunnyCdnUrl(config, path, expiry), {
      redirect: "error", signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) throw new Error("Could not load preview");
    const content = await response.text();
    if (!content.startsWith("#EXTM3U") || content.length > 2_000_000) throw new Error("Invalid playlist");
    return content;
  }
  let path = master;
  let manifest = await get(path);
  if (manifest.includes("#EXT-X-STREAM-INF")) {
    if (/#EXT-X-MEDIA:.*TYPE=AUDIO/.test(manifest)) throw new Error("Automatic preview requires muxed audio");
    const first = /#EXT-X-STREAM-INF:[^\r\n]*\r?\n([^#\r\n][^\r\n]*)/.exec(manifest)?.[1].trim();
    if (!first) throw new Error("Missing preview rendition");
    path = resolveAsset(config.origin, master, directory, first);
    if (!path.endsWith(".m3u8")) throw new Error("Missing media playlist");
    manifest = await get(path);
  }
  return await cutPreview(config, path, directory, manifest, expiry);
}
