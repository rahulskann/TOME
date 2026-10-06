import 'package:flutter/material.dart';

import '../pack/pack.dart';
import '../progress/progress_store.dart';
import 'marker_badge.dart';
import 'marker_filter.dart';

/// Opens the full category filter: every group and category, with found /
/// total counts for [markers] (the current map's).
Future<void> showFilterSheet(
  BuildContext context, {
  required PackManifest manifest,
  required MarkerFilter filter,
  required ProgressStore progress,
  required List<MapMarker> markers,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListenableBuilder(
        listenable: Listenable.merge([filter, progress]),
        builder: (context, _) => _FilterList(
          manifest: manifest,
          filter: filter,
          progress: progress,
          markers: markers,
          scrollController: scrollController,
        ),
      ),
    ),
  );
}

class _FilterList extends StatelessWidget {
  const _FilterList({
    required this.manifest,
    required this.filter,
    required this.progress,
    required this.markers,
    required this.scrollController,
  });

  final PackManifest manifest;
  final MarkerFilter filter;
  final ProgressStore progress;
  final List<MapMarker> markers;
  final ScrollController scrollController;

  Iterable<MapMarker> _inCategories(Iterable<String> ids) {
    final set = ids.toSet();
    return markers.where((m) => set.contains(m.category));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final allIds = [for (final c in manifest.categories) c.id];
    final overall = progress.tally(markers);
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 12, 0),
          child: Row(
            children: [
              Expanded(child: Text('Filters', style: text.titleLarge)),
              TextButton(
                onPressed: () => filter.setVisible(allIds, true),
                child: const Text('Show all'),
              ),
              TextButton(
                onPressed: () => filter.setVisible(allIds, false),
                child: const Text('Hide all'),
              ),
            ],
          ),
        ),
        if (overall.total > 0) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: _ProgressLine(found: overall.found, total: overall.total, label: 'This map'),
          ),
          SwitchListTile(
            value: filter.hideFound,
            onChanged: (v) => filter.hideFound = v,
            title: const Text('Hide found'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          ),
          const Divider(),
        ],
        for (final (group, categories) in manifest.groupedCategories) ...[
          _GroupHeader(
            group: group,
            categories: categories,
            filter: filter,
            tally: progress.tally(_inCategories(categories.map((c) => c.id))),
            count: _inCategories(categories.map((c) => c.id)).length,
          ),
          for (final c in categories)
            CheckboxListTile(
              value: filter.isVisible(c.id),
              onChanged: (_) => filter.toggle(c.id),
              secondary: CategoryBadge(category: c, size: 32),
              title: Text(c.name),
              subtitle: Text(_summary(
                progress.tally(_inCategories([c.id])),
                _inCategories([c.id]).length,
              )),
              contentPadding: const EdgeInsets.only(left: 40, right: 16),
            ),
        ],
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.categories,
    required this.filter,
    required this.tally,
    required this.count,
  });

  final CategoryGroup group;
  final List<MarkerCategory> categories;
  final MarkerFilter filter;
  final ({int found, int total}) tally;
  final int count;

  @override
  Widget build(BuildContext context) {
    final visible = categories.where((c) => filter.isVisible(c.id)).length;
    return CheckboxListTile(
      tristate: true,
      value: visible == categories.length ? true : (visible == 0 ? false : null),
      // Tristate checkboxes cycle true -> null -> false; treat any tap from
      // "all shown" as hide-all and anything else as show-all.
      onChanged: (_) => filter.setVisible(
          [for (final c in categories) c.id], visible != categories.length),
      title: Text(group.name, style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(_summary(tally, count)),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.found, required this.total, required this.label});

  final int found;
  final int total;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: $found of $total found'),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: total == 0 ? 0 : found / total),
      ],
    );
  }
}

/// "3 / 12 found" for trackable markers, else a plain count.
String _summary(({int found, int total}) tally, int count) {
  if (tally.total > 0) return '${tally.found} / ${tally.total} found';
  return count == 1 ? '1 marker' : '$count markers';
}
