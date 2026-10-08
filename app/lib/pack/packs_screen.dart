import 'dart:async';

import 'package:flutter/material.dart';

import '../about.dart';
import '../map/map_screen.dart';
import '../map/marker_filter.dart';
import '../progress/progress_store.dart';
import 'add_pack_screen.dart';
import 'pack_installer.dart';
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
    unawaited(_fetchMissingIcons(packs));
    return packs;
  }

  /// Packs installed before the app knew about custom icons (or while offline)
  /// get them in the background; the list redraws once they arrive.
  Future<void> _fetchMissingIcons(List<InstalledPack> packs) async {
    var got = 0;
    for (final pack in packs) {
      got += await fetchMissingIcons(pack).catchError((_) => 0);
    }
    if (got > 0 && mounted) _reload();
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

  void _reload() {
    final reload = _load();
    setState(() {
      _packs = reload;
    });
  }

  Future<void> _addPack() async {
    final added = await Navigator.of(context).push<InstalledPack>(
        MaterialPageRoute(builder: (_) => const AddPackScreen()));
    if (added != null && mounted) {
      _reload();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Installed ${added.manifest.name}')));
    }
  }

  /// Asks where [pack] is published, prefilled with a guess.
  Future<String?> _askForLink(InstalledPack pack) {
    final controller = TextEditingController(text: guessPackLink(pack.manifest));
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Where is ${pack.manifest.name} published?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This copy wasn\'t added from a link, so enter the link it\'s published at. '
                'It\'s remembered for next time.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Pack link',
                hintText: 'owner/repo/folder',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Check'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _checkForUpdate(InstalledPack pack, {String? link}) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Checking for updates…')));
    try {
      final update = await checkForUpdate(pack, link: link);
      messenger.hideCurrentSnackBar();
      if (!mounted) return;
      if (update == null) {
        messenger.showSnackBar(
            SnackBar(content: Text('${pack.manifest.name} is up to date (v${pack.manifest.version})')));
        return;
      }
      final edited = await hasLocalMarkerEdits(pack);
      if (!mounted) return;
      final installed = await Navigator.of(context).push<InstalledPack>(MaterialPageRoute(
          builder: (_) => AddPackScreen(update: update, replacesEdits: edited)));
      if (installed != null && mounted) {
        _reload();
        messenger.showSnackBar(SnackBar(
            content: Text('Updated ${installed.manifest.name} to v${installed.manifest.version}')));
      }
    } on PackNeedsLink {
      messenger.hideCurrentSnackBar();
      if (!mounted) return;
      final entered = await _askForLink(pack);
      if (entered != null && entered.isNotEmpty && mounted) {
        await _checkForUpdate(pack, link: entered);
      }
    } on PackFetchException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(InstalledPack pack) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${pack.manifest.name}?'),
        content: const Text('Its maps are removed from this device. Your found progress is kept, '
            'so reinstalling it later restores your progress.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await deletePack(pack);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TOME'),
        actions: [
          IconButton(
            tooltip: 'About, make a pack, support',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showTomeAbout(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPack,
        icon: const Icon(Icons.add),
        label: const Text('Add pack'),
      ),
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
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: [
                for (final pack in packs)
                  _PackCard(
                    pack: pack,
                    progress: _progress[pack.manifest.id]!,
                    onTap: () => _open(pack),
                    onCheckUpdate: isBundled(pack) ? null : () => _checkForUpdate(pack),
                    onDelete: isBundled(pack) ? null : () => _delete(pack),
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
  const _PackCard({
    required this.pack,
    required this.progress,
    required this.onTap,
    this.onCheckUpdate,
    this.onDelete,
  });

  final InstalledPack pack;
  final ProgressStore progress;
  final VoidCallback onTap;
  final VoidCallback? onCheckUpdate;
  final VoidCallback? onDelete;

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
            trailing: onCheckUpdate == null && onDelete == null
                ? const Icon(Icons.chevron_right)
                : PopupMenuButton<VoidCallback>(
                    onSelected: (action) => action(),
                    itemBuilder: (_) => [
                      if (onCheckUpdate case final f?)
                        PopupMenuItem(value: f, child: const Text('Check for update')),
                      if (onDelete case final f?)
                        PopupMenuItem(value: f, child: const Text('Delete')),
                    ],
                  ),
            onTap: onTap,
          );
        },
      ),
    );
  }
}
