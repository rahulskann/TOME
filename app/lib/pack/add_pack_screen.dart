import 'package:flutter/material.dart';

import 'pack_installer.dart';
import 'pack_store.dart';

/// Add a pack from a link, or install an update found for an existing pack.
/// Pops with the installed pack on success.
class AddPackScreen extends StatefulWidget {
  const AddPackScreen({super.key, this.update, this.replacesEdits = false});

  /// When set, skip the link step and offer this version as an update.
  final RemotePack? update;

  /// The pack being updated has marker edits that the update will replace.
  final bool replacesEdits;

  @override
  State<AddPackScreen> createState() => _AddPackScreenState();
}

class _AddPackScreenState extends State<AddPackScreen> {
  final _link = TextEditingController();
  late RemotePack? _remote = widget.update;
  bool _fetching = false;
  String? _error;
  InstallProgress? _progress;
  CancelToken? _cancel;

  bool get _installing => _progress != null;

  @override
  void dispose() {
    _cancel?.cancelled = true;
    _link.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _fetching = true;
      _error = null;
      _remote = null;
    });
    try {
      final remote = await fetchRemotePack(_link.text);
      if (mounted) setState(() => _remote = remote);
    } on PackFetchException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _install() async {
    final remote = _remote!;
    final cancel = CancelToken();
    setState(() {
      _cancel = cancel;
      _error = null;
      _progress = const InstallProgress('Starting');
    });
    try {
      final pack = await installRemotePack(remote,
          cancel: cancel, onProgress: (p) => mounted ? setState(() => _progress = p) : null);
      if (mounted) Navigator.of(context).pop<InstalledPack>(pack);
    } on InstallCancelled {
      if (mounted) setState(() => _error = 'Cancelled. Downloading again will pick up where it stopped.');
    } on PackFetchException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Install failed: $e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUpdate = widget.update != null;
    return PopScope(
      canPop: !_installing,
      child: Scaffold(
        appBar: AppBar(title: Text(isUpdate ? 'Update pack' : 'Add a pack')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!isUpdate) ...[
              const Text('Paste a link to a pack on GitHub, e.g. owner/repo, owner/repo/folder, '
                  'or a github.com link.'),
              const SizedBox(height: 12),
              TextField(
                controller: _link,
                enabled: !_installing,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Pack link',
                  hintText: 'owner/repo/folder',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _find(),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _fetching || _installing ? null : _find,
                  child: const Text('Find pack'),
                ),
              ),
            ],
            if (_fetching) const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(leading: const Icon(Icons.error_outline), title: Text(_error!)),
              ),
            if (_remote case final remote?) ...[
              const SizedBox(height: 8),
              _Preview(remote: remote),
              if (widget.replacesEdits)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.warning_amber),
                    title: Text('You\'ve edited markers in this pack on this device.'),
                    subtitle: Text('Updating replaces them with the published markers. '
                        'Export them first (map ⋮ menu → Export markers) to keep them. '
                        'Your found progress is kept.'),
                  ),
                ),
              const SizedBox(height: 16),
              if (_progress case final progress?) ...[
                Text(progress.message),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress.fraction),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _cancel?.cancelled = true,
                    child: const Text('Cancel'),
                  ),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _install,
                  icon: const Icon(Icons.download),
                  label: Text([
                    isUpdate ? 'Update' : 'Download',
                    if (remote.downloadBytes case final b?) '(${formatBytes(b)})',
                  ].join(' ')),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.remote});

  final RemotePack remote;

  @override
  Widget build(BuildContext context) {
    final m = remote.manifest;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.name, style: text.titleLarge),
            Text([if (m.game != null) m.game!, 'v${m.version}', if (m.author != null) 'by ${m.author}']
                .join(' · ')),
            if (m.description != null) ...[
              const SizedBox(height: 8),
              Text(m.description!),
            ],
            const SizedBox(height: 12),
            Text('Maps', style: text.titleSmall),
            for (final map in m.maps)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(Icons.map_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(map.name)),
                    if (map.archiveBytes case final b?) Text(formatBytes(b), style: text.bodySmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
