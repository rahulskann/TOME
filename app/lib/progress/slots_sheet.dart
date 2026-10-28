import 'package:flutter/material.dart';

import '../pack/pack.dart';
import 'progress_store.dart';

/// A pack's save slots, like save files in a game: switch, add, rename, delete.
Future<void> showSlotsSheet(
  BuildContext context, {
  required ProgressStore progress,
  required Iterable<MapMarker> markers,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _SlotsSheet(progress: progress, markers: markers.toList()),
  );
}

/// The label for a slot; the first slot has no name until a second is added.
String slotLabel(SaveSlot slot) => slot.name ?? 'Unnamed slot';

class _SlotsSheet extends StatelessWidget {
  const _SlotsSheet({required this.progress, required this.markers});

  final ProgressStore progress;
  final List<MapMarker> markers;

  Future<void> _add(BuildContext context) async {
    final first = progress.slots.length == 1 ? progress.slots.single : null;
    final needsCurrentName = first != null && first.name == null;
    final names = await showDialog<List<String>>(
      context: context,
      builder: (_) => _NamesDialog(
        title: 'New save slot',
        message: needsCurrentName
            ? 'Name both slots so you can tell them apart. The new one starts with nothing found.'
            : 'It starts with nothing found.',
        fields: [
          if (needsCurrentName) ('Your current progress', 'e.g. First run', ''),
          ('New slot', 'e.g. Steel Soul', ''),
        ],
        taken: [for (final s in progress.slots) ?s.name],
        confirm: 'Add',
      ),
    );
    if (names == null || !context.mounted) return;
    final slot = await progress.addSlot(names.last, currentName: needsCurrentName ? names.first : null);
    if (!context.mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Now on ${slotLabel(slot)}')));
  }

  Future<void> _rename(BuildContext context, SaveSlot slot) async {
    final names = await showDialog<List<String>>(
      context: context,
      builder: (_) => _NamesDialog(
        title: 'Rename slot',
        fields: [('Name', '', slot.name ?? '')],
        taken: [for (final s in progress.slots) if (s.id != slot.id) ?s.name],
        confirm: 'Rename',
      ),
    );
    if (names != null) progress.renameSlot(slot.id, names.single);
  }

  Future<void> _delete(BuildContext context, SaveSlot slot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${slotLabel(slot)}?'),
        content: const Text('Its found markers are deleted. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await progress.deleteSlot(slot.id);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: ListenableBuilder(
        listenable: progress,
        builder: (context, _) {
          final slots = progress.slots;
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text('Save slots', style: text.titleLarge),
              const SizedBox(height: 4),
              Text('Each slot keeps its own found markers, like save files in a game.',
                  style: text.bodyMedium),
              const SizedBox(height: 8),
              for (final slot in slots)
                _SlotTile(
                  key: ValueKey(slot.id),
                  slot: slot,
                  active: slot.id == progress.activeSlot.id,
                  tally: progress.tallyIn(slot.id, markers),
                  onTap: () async {
                    await progress.switchTo(slot.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                  onRename: () => _rename(context, slot),
                  onDelete: slots.length > 1 ? () => _delete(context, slot) : null,
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Add slot'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({
    super.key,
    required this.slot,
    required this.active,
    required this.tally,
    required this.onTap,
    required this.onRename,
    this.onDelete,
  });

  final SaveSlot slot;
  final bool active;
  final Future<({int found, int total})> tally;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: active ? Theme.of(context).colorScheme.primary : null),
      title: Text(slotLabel(slot)),
      subtitle: FutureBuilder(
        future: tally,
        builder: (context, snap) => Text(switch (snap.data) {
          (:final found, :final total) => '$found of $total found${active ? ' · playing now' : ''}',
          null => ' ',
        }),
      ),
      trailing: PopupMenuButton<VoidCallback>(
        tooltip: 'Slot options',
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          PopupMenuItem(value: onRename, child: const Text('Rename')),
          if (onDelete case final f?) PopupMenuItem(value: f, child: const Text('Delete')),
        ],
      ),
      onTap: active ? null : onTap,
    );
  }
}

/// Asks for one or more names: each required, and different from [taken] and
/// from each other (ignoring case). Pops with the names in field order.
class _NamesDialog extends StatefulWidget {
  const _NamesDialog({
    required this.title,
    required this.fields,
    required this.taken,
    required this.confirm,
    this.message,
  });

  final String title;
  final String? message;

  /// (label, hint, initial value) per field.
  final List<(String, String, String)> fields;
  final List<String> taken;
  final String confirm;

  @override
  State<_NamesDialog> createState() => _NamesDialogState();
}

class _NamesDialogState extends State<_NamesDialog> {
  late final _controllers = [for (final (_, _, initial) in widget.fields) TextEditingController(text: initial)];
  List<String?> _errors = [];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final names = [for (final c in _controllers) c.text.trim()];
    final used = {for (final t in widget.taken) t.toLowerCase()};
    final errors = <String?>[];
    for (final name in names) {
      final key = name.toLowerCase();
      errors.add(name.isEmpty
          ? 'Give it a name'
          : used.contains(key)
              ? 'Another slot already has this name'
              : null);
      used.add(key);
    }
    setState(() => _errors = errors);
    if (errors.every((e) => e == null)) Navigator.pop(context, names);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message case final m?) ...[Text(m), const SizedBox(height: 12)],
          for (final (i, (label, hint, _)) in widget.fields.indexed) ...[
            if (i > 0) const SizedBox(height: 12),
            TextField(
              controller: _controllers[i],
              autofocus: i == 0,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: i == widget.fields.length - 1 ? TextInputAction.done : TextInputAction.next,
              onSubmitted: i == widget.fields.length - 1 ? (_) => _submit() : null,
              decoration: InputDecoration(
                labelText: label,
                hintText: hint.isEmpty ? null : hint,
                errorText: i < _errors.length ? _errors[i] : null,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}
