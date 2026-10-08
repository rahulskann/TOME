// Fetching GitHub release files through the tile relay (relay/worker.js),
// since browsers can't read release downloads directly.

/** The relay's address, set at build time (Vercel env var VITE_TILE_RELAY). */
export const RELAY_URL: string | undefined = relayAddress(import.meta.env.VITE_TILE_RELAY);

/** Normalizes the configured address: adds https:// if it was left off, drops a trailing slash. */
export function relayAddress(raw: string | undefined): string | undefined {
  const v = raw?.trim().replace(/\/+$/, '');
  if (!v) return undefined;
  return /^https?:\/\//.test(v) ? v : `https://${v}`;
}

const RELEASE_ZIP = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/releases\/download\/[^/?#]+\/[^/?#]+\.zip$/;

/** Whether `archive` can be fetched through the relay. */
export const relayable = (archive: string) => RELAY_URL !== undefined && RELEASE_ZIP.test(archive);

/** Downloads a release zip via the relay, reporting (received, total) bytes. */
export async function fetchViaRelay(
  archive: string,
  onProgress?: (received: number, total?: number) => void,
): Promise<Blob> {
  let resp: Response;
  try {
    resp = await fetch(`${RELAY_URL}/?url=${encodeURIComponent(archive)}`);
  } catch {
    throw new Error(`Couldn't reach the tile relay at ${RELAY_URL}. Check it's deployed and that ` +
      `ALLOWED_ORIGINS in its settings includes ${location.origin}.`);
  }
  if (!resp.ok) throw new Error(`The relay couldn't get ${archive.split('/').pop()} (${resp.status}: ${await resp.text()})`);
  const total = Number(resp.headers.get('Content-Length')) || undefined;
  if (!resp.body) return resp.blob();
  const reader = resp.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.length;
    onProgress?.(received, total);
  }
  return new Blob(chunks as BlobPart[], { type: 'application/zip' });
}
