import 'package:flutter/material.dart';

import '../map/map_screen.dart';
import '../map/marker_filter.dart';
import '../progress/progress_store.dart';
import 'pack_store.dart';

/// Lists the packs installed on this device.
class PacksScreen extends StatefulWidget {
  const PacksScreen({super.key});

  @override
  State<PacksScreen> createState() => _PacksScreenState();
}

class _PacksScreenState extends State<PacksScreen> {
  late Future<List<InstalledPack>> _packs = _load();
  final List<String> _errors = [];

  /// Progress per pack id, shared with the map screen so the cards update.
  final Map<String, ProgressStore> _progress = {};

  Future<List<InstalledPack>> _load() async {
    _errors.clear();
    await installBundledPack('assets/packs/tome.demo');
    final packs = await listInstalledPacks(
        onError: (dir, e) => _errors.add('${dir.split(RegExp(r'[/\\]')).last}: $e'));
    for (final pack in packs) {
      _progress[pack.manifest.id] ??= await ProgressStore.load(pack.manifest.id);
    }
    return packs;
  }

  Future<void> _open(InstalledPack pack) async {
    final filter = await MarkerFilter.load(pack.manifest.id);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MapScreen(
        pack: pack,
        filter: filter,
        progress: _progress[pack.manifest.id]!,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TOME')),
      body: FutureBuilder(
        future: _packs,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Could not read packs:\n${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final packs = snapshot.data!;
          return RefreshIndicator(
            onRefresh: () async {
              final reload = _load();
              setState(() {
                _packs = reload;
              });
              await reload;
            },
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final pack in packs)
                  _PackCard(
                    pack: pack,
                    progress: _progress[pack.manifest.id]!,
                    onTap: () => _open(pack),
                  ),
                for (final e in _errors)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: const Text('Pack could not be opened'),
                      subtitle: Text(e),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PackCard extends StatelessWidget {
  const _PackCard({required this.pack, required this.progress, required this.onTap});

  final InstalledPack pack;
  final ProgressStore progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = pack.manifest;
    final markerCount = pack.markers.values.fold(0, (n, list) => n + list.length);
    final details = [
      if (m.game != null) m.game!,
      m.maps.length == 1 ? '1 map' : '${m.maps.length} maps',
      '$markerCount markers',
      'v${m.version}',
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: progress,
        builder: (context, _) {
          final tally = progress.tally(pack.markers.values.expand((l) => l));
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: const Icon(Icons.map_outlined, size: 32),
            title: Text(m.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(details.join(' · ')),
                if (tally.total > 0) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: tally.found / tally.total),
                  const SizedBox(height: 4),
                  Text('${tally.found} of ${tally.total} found'),
                ],
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onTap,
          );
        },
      ),
    );
  }
}
