import 'package:flutter/material.dart';

import '../map/marker_badge.dart';
import '../pack/pack.dart';
import '../progress/progress_store.dart';
import 'marker_search.dart';

/// Full-screen search over every marker in a pack; returns the chosen hit.
class MarkerSearchDelegate extends SearchDelegate<SearchHit?> {
  MarkerSearchDelegate({
    required this.manifest,
    required this.markers,
    required this.progress,
  }) : super(searchFieldLabel: 'Search ${manifest.name}');

  final PackManifest manifest;
  final Map<String, List<MapMarker>> markers;
  final ProgressStore progress;

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.clear),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => BackButton(onPressed: () => close(context, null));

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    if (query.trim().isEmpty) {
      return const _Hint(text: 'Search by name, type, area or notes');
    }
    final hits = searchMarkers(manifest, markers, query);
    if (hits.isEmpty) return _Hint(text: 'Nothing matches "$query"');
    final multiMap = manifest.maps.length > 1;
    return ListView.builder(
      itemCount: hits.length,
      itemBuilder: (context, i) {
        final hit = hits[i];
        final region = hit.region;
        if (region != null) {
          return ListTile(
            leading: CircleAvatar(
              child: Icon(region.map != null ? Icons.map_outlined : Icons.place_outlined),
            ),
            title: Text(region.name),
            subtitle: Text([
              region.map != null ? 'Region · opens its map' : 'Area',
              if (multiMap) hit.map.name,
            ].join(' · ')),
            onTap: () => close(context, hit),
          );
        }
        final m = hit.marker!;
        final category = manifest.category(m.category);
        return ListTile(
          leading: CategoryBadge(
            category: category,
            size: 32,
            found: m.trackable && progress.isFound(m.id),
          ),
          title: Text(m.name),
          subtitle: Text([
            if (category != null) category.name,
            if (multiMap) hit.map.name,
          ].join(' · ')),
          onTap: () => close(context, hit),
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
