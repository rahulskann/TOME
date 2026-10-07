// What a user pastes -> folder URLs where pack.json might be.
// Port of app/lib/pack/pack_location.dart; keep the two in step.

export function packFolderCandidates(input: string): string[] {
  let text = input.trim();
  if (!text) return [];
  if (text.endsWith('.git')) text = text.slice(0, -4);

  const hasScheme = text.includes('://');
  const shorthand =
    !hasScheme &&
    !text.startsWith('github.com') &&
    !text.startsWith('raw.githubusercontent.com') &&
    /^[\w.-]+\/[\w.-]+(\/.*)?$/.test(text);
  if (shorthand) text = `github.com/${text}`;

  let url: URL;
  try {
    url = new URL(hasScheme ? text : `https://${text}`);
  } catch {
    return [];
  }
  if (!url.hostname.includes('.')) return [];
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return [];

  let segments = url.pathname.split('/').filter(Boolean);
  if (segments.at(-1) === 'pack.json') segments = segments.slice(0, -1);
  const raw = (owner: string, repo: string, ref: string, folder: string[]) =>
    `https://raw.githubusercontent.com/${[owner, repo, ref, ...folder].join('/')}/`;

  switch (url.hostname) {
    case 'github.com':
    case 'www.github.com': {
      if (segments.length < 2) return [];
      const [owner, repo, ...rest] = segments;
      if (rest.length >= 2 && (rest[0] === 'tree' || rest[0] === 'blob')) {
        return [raw(owner, repo, rest[1], rest.slice(2))];
      }
      return ['main', 'master'].map((ref) => raw(owner, repo, ref, rest));
    }
    case 'raw.githubusercontent.com':
      if (segments.length < 3) return [];
      return [`https://raw.githubusercontent.com/${segments.join('/')}/`];
    default:
      return [`${url.protocol}//${url.host}/${segments.length ? segments.join('/') + '/' : ''}`];
  }
}
