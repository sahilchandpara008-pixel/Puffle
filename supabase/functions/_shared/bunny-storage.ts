export type BunnyStorage = { endpoint: URL; zone: string; password: string; cdn: URL; tokenKey: string };

export function readBunnyStorage(env: (name: string) => string | undefined): BunnyStorage | null {
  const [host, zone, password, cdnHost, tokenKey] = [
    'BUNNY_STORAGE_HOST', 'BUNNY_STORAGE_ZONE', 'BUNNY_STORAGE_PASSWORD',
    'BUNNY_STORAGE_CDN_HOST', 'BUNNY_STORAGE_TOKEN_KEY',
  ].map((name) => env(name)?.trim());
  if (!host || !zone || !password || !cdnHost || !tokenKey) return null;
  if (!/^(?:[a-z0-9-]+\.)?storage\.bunnycdn\.com$/i.test(host)
      || !/^[a-z0-9][a-z0-9-]*$/i.test(zone)
      || !/^[a-z0-9][a-z0-9-]*\.b-cdn\.net$/i.test(cdnHost)) {
    throw new Error('Invalid Bunny Storage configuration');
  }
  return { endpoint: new URL(`https://${host}`), zone, password,
    cdn: new URL(`https://${cdnHost}`), tokenKey };
}

export function bunnyObjectPath(userId: string, fileId: string): string {
  const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
  if (!uuid.test(userId) || !uuid.test(fileId)) throw new Error('Invalid cloud file identity');
  return `/puffle/${userId}/${fileId}`;
}

export async function bunnyDownloadUrl(config: BunnyStorage, path: string, expires: number) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(config.tokenKey),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, enc.encode(`${path}${expires}`));
  const token = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const url = new URL(path, config.cdn);
  url.searchParams.set('token', `HS256-${token}`);
  url.searchParams.set('expires', String(expires));
  return url.toString();
}

export async function bunnyStorageRequest(config: BunnyStorage, path: string, init: RequestInit) {
  const headers = new Headers(init.headers);
  headers.set('AccessKey', config.password);
  return await fetch(new URL(`/${config.zone}${path}`, config.endpoint), {
    ...init, headers, redirect: 'error', signal: init.signal ?? AbortSignal.timeout(90_000),
  });
}

export async function removeBunnyObject(config: BunnyStorage, path: string) {
  const response = await bunnyStorageRequest(config, path, { method: 'DELETE' });
  await response.body?.cancel();
  if (!response.ok && response.status !== 404) throw new Error('Bunny object deletion failed');
}
