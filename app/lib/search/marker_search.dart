import '../pack/pack.dart';

/// A marker or a region, on the map it belongs to.
class SearchHit {
  const SearchHit.marker({required this.map, required MapMarker this.marker, required this.score})
      : region = null;
  const SearchHit.region({required this.map, required MapRegion this.region, required this.score})
      : marker = null;

  final MapDefinition map;
  final MapMarker? marker;
  final MapRegion? region;
  final int score;

  String get name => marker?.name ?? region!.name;
}

/// Finds markers and regions across every map of a pack.
///
/// Every word of [query] must match the name, category, map or notes. Name
/// matches rank highest (exact, then prefix, then a word in the name), then
/// category, map and notes; ties keep pack order, regions before markers.
List<SearchHit> searchMarkers(
  PackManifest manifest,
  Map<String, List<MapMarker>> markers,
  String query, {
  int limit = 100,
}) {
  final terms = _normalise(query).split(' ').where((t) => t.isNotEmpty).toList();
  if (terms.isEmpty) return const [];
  final whole = terms.join(' ');

  int? score({required String name, String category = '', required String map, String notes = ''}) {
    var total = 0;
    for (final term in terms) {
      final s = _nameScore(name, term) ??
          (category.contains(term) ? 30 : null) ??
          (map.contains(term) ? 20 : null) ??
          (notes.contains(term) ? 10 : null);
      if (s == null) return null;
      total += s;
    }
    return name == whole ? total + 200 : total;
  }

  final hits = <SearchHit>[];
  for (final map in manifest.maps) {
    final mapName = _normalise(map.name);
    for (final region in map.regions) {
      final s = score(
        name: _normalise(region.name),
        category: region.map != null ? 'region' : 'area',
        map: mapName,
        notes: _normalise(region.description ?? ''),
      );
      if (s != null) hits.add(SearchHit.region(map: map, region: region, score: s));
    }
    for (final marker in markers[map.id] ?? const <MapMarker>[]) {
      final s = score(
        name: _normalise(marker.name),
        category: _normalise(manifest.category(marker.category)?.name ?? ''),
        map: mapName,
        notes: _normalise(marker.description ?? ''),
      );
      if (s != null) hits.add(SearchHit.marker(map: map, marker: marker, score: s));
    }
  }
  // List.sort isn't stable; break ties by original position.
  final order = {for (var i = 0; i < hits.length; i++) hits[i]: i};
  hits.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : order[a]!.compareTo(order[b]!);
  });
  return hits.length > limit ? hits.sublist(0, limit) : hits;
}

int? _nameScore(String name, String term) {
  if (name.startsWith(term)) return 80;
  if (name.split(' ').any((w) => w.startsWith(term))) return 60;
  if (name.contains(term)) return 50;
  return null;
}

/// Lowercase, apostrophes dropped (so "hunters" finds "Hunter's"), other
/// punctuation treated as spaces.
String _normalise(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();
