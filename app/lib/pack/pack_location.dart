/// Turns what a user pastes into the URLs where a pack's `pack.json` might be.
///
/// Accepted, with or without `https://`:
/// - `owner/repo` or `owner/repo/sub/folder` (GitHub shorthand)
/// - `github.com/owner/repo[/tree/<ref>/sub/folder]`
/// - `github.com/owner/repo/blob/<ref>/sub/folder/pack.json`
/// - `raw.githubusercontent.com/owner/repo/<ref>/sub/folder[/pack.json]`
/// - any other `https://host/path/` folder or `.../pack.json`
///
/// Returns candidate *folder* URLs (ending in `/`) to try in order; for GitHub
/// links without a branch, `main` then `master`.
List<Uri> packFolderCandidates(String input) {
  var text = input.trim();
  if (text.isEmpty) return const [];
  if (text.endsWith('.git')) text = text.substring(0, text.length - 4);

  final hasScheme = text.contains('://');
  final looksLikeShorthand = !hasScheme &&
      !text.startsWith('github.com') &&
      !text.startsWith('raw.githubusercontent.com') &&
      RegExp(r'^[\w.-]+/[\w.-]+(/.*)?$').hasMatch(text);
  if (looksLikeShorthand) text = 'github.com/$text';
  final uri = Uri.tryParse(hasScheme ? text : 'https://$text');
  // Hosts need a dot, so a stray word isn't taken for a website.
  if (uri == null || !uri.host.contains('.')) return const [];
  if (uri.scheme != 'https' && uri.scheme != 'http') return const [];

  var segments = [...uri.pathSegments.where((s) => s.isNotEmpty)];
  if (segments.isNotEmpty && segments.last == 'pack.json') {
    segments = segments.sublist(0, segments.length - 1);
  }

  Uri raw(String owner, String repo, String ref, List<String> folder) => Uri.https(
      'raw.githubusercontent.com', '/${[owner, repo, ref, ...folder].join('/')}/');

  switch (uri.host) {
    case 'github.com' || 'www.github.com':
      if (segments.length < 2) return const [];
      final [owner, repo, ...rest] = segments;
      if (rest.length >= 2 && (rest[0] == 'tree' || rest[0] == 'blob')) {
        return [raw(owner, repo, rest[1], rest.sublist(2))];
      }
      return [for (final ref in const ['main', 'master']) raw(owner, repo, ref, rest)];
    case 'raw.githubusercontent.com':
      if (segments.length < 3) return const [];
      return [Uri.https(uri.host, '/${segments.join('/')}/')];
    default:
      final path = segments.isEmpty ? '/' : '/${segments.join('/')}/';
      return [Uri(scheme: uri.scheme, host: uri.host, port: uri.port, path: path)];
  }
}

/// Resolves a path from `pack.json` (a tile archive or markers file) against
/// the pack's folder; absolute URLs pass through.
Uri resolveInPack(Uri folder, String path) => folder.resolve(path);
