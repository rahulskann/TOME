import 'package:flutter/material.dart';

import '../pack/pack.dart';
import '../progress/progress_store.dart';

/// About the current map: its description and its regions/areas, each with
/// found counts, notes, and a way to go there.
Future<void> showMapInfoSheet(
  BuildContext context, {
  required PackManifest manifest,
  required MapDefinition map,
  required Map<String, List<MapMarker>> markers,
  required ProgressStore progress,
  required void Function(MapRegion) onGoTo,
  required void Function(MarkerLink) onOpenLink,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListenableBuilder(
        listenable: progress,
        builder: (context, _) => _MapInfo(
          manifest: manifest,
          map: map,
          markers: markers,
          progress: progress,
          scroll: scroll,
          onGoTo: (r) {
            Navigator.of(context).pop();
            onGoTo(r);
          },
          onOpenLink: onOpenLink,
        ),
      ),
    ),
  );
}

class _MapInfo extends StatelessWidget {
  const _MapInfo({
    required this.manifest,
    required this.map,
    required this.markers,
    required this.progress,
    required this.scroll,
    required this.onGoTo,
    required this.onOpenLink,
  });

  final PackManifest manifest;
  final MapDefinition map;
  final Map<String, List<MapMarker>> markers;
  final ProgressStore progress;
  final ScrollController scroll;
  final void Function(MapRegion) onGoTo;
  final void Function(MarkerLink) onOpenLink;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tally = progress.tally(markers[map.id] ?? const []);
    final mapWiki = map.wiki == null ? null : manifest.wikiUrl(map.wiki!);
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Text(map.name, style: text.headlineSmall),
        Text(manifest.name, style: text.bodySmall),
        if (tally.total > 0) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: tally.found / tally.total),
          const SizedBox(height: 4),
          Text('${tally.found} of ${tally.total} found on this map'),
        ],
        if (map.description != null) ...[
          const SizedBox(height: 16),
          Text(map.description!, style: text.bodyLarge),
          if (map.source case final source?) _CreditLink(source: source, onOpen: onOpenLink),
        ],
        if (mapWiki != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => onOpenLink(MarkerLink(label: map.name, url: mapWiki)),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Wiki'),
            ),
          ),
        ],
        if (map.regions.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(map.regions.any((r) => r.map != null) ? 'Regions' : 'Areas',
              style: text.titleMedium),
          const SizedBox(height: 4),
          for (final region in map.regions) _regionTile(context, region),
        ],
      ],
    );
  }

  Widget _regionTile(BuildContext context, MapRegion region) {
    final opensMap = manifest.map(region.map) != null;
    final t = progress.tally(manifest.markersIn(map, region, markers));
    final wiki = region.wiki == null ? null : manifest.wikiUrl(region.wiki!);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: Icon(opensMap ? Icons.map_outlined : Icons.place_outlined),
      title: Text(region.name),
      subtitle: t.total > 0 ? Text('${t.found} / ${t.total} found') : null,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      childrenPadding: const EdgeInsets.only(left: 40, bottom: 12),
      children: [
        if (region.description != null) Text(region.description!),
        if (region.source case final source?) _CreditLink(source: source, onOpen: onOpenLink),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => onGoTo(region),
              icon: Icon(opensMap ? Icons.zoom_in_map : Icons.my_location, size: 18),
              label: Text(opensMap ? 'Open map' : 'Go there'),
            ),
            if (wiki != null)
              OutlinedButton.icon(
                onPressed: () => onOpenLink(MarkerLink(label: region.name, url: wiki)),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Wiki'),
              ),
          ],
        ),
      ],
    );
  }
}

class _CreditLink extends StatelessWidget {
  const _CreditLink({required this.source, required this.onOpen});

  final ContentSource source;
  final void Function(MarkerLink) onOpen;

  @override
  Widget build(BuildContext context) {
    final url = source.url;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        onTap: url == null ? null : () => onOpen(MarkerLink(label: source.name, url: url)),
        child: Text(
          source.credit,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                decoration: url != null ? TextDecoration.underline : null,
              ),
        ),
      ),
    );
  }
}
