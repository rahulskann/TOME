import 'package:flutter/material.dart';

import '../pack/pack.dart';
import 'marker_badge.dart';

/// What the user chose in the marker editor.
sealed class MarkerEdit {
  const MarkerEdit();
}

class MarkerSaved extends MarkerEdit {
  const MarkerSaved(this.marker);
  final MapMarker marker;
}

class MarkerDeleted extends MarkerEdit {
  const MarkerDeleted();
}

/// The user wants to pick a new position for the (possibly edited) marker.
class MarkerMoveRequested extends MarkerEdit {
  const MarkerMoveRequested(this.marker);
  final MapMarker marker;
}

/// Edits [marker], or creates one at ([x], [y]) when [marker] is null.
/// [newId] makes an id for a new marker from its category and name.
Future<MarkerEdit?> showMarkerEditor(
  BuildContext context, {
  required PackManifest manifest,
  MapMarker? marker,
  required double x,
  required double y,
  required String Function(String? category, String name) newId,
  String? lastCategory,
}) {
  return showModalBottomSheet<MarkerEdit>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _MarkerEditor(
      manifest: manifest,
      marker: marker,
      x: x,
      y: y,
      newId: newId,
      lastCategory: lastCategory,
    ),
  );
}

class _MarkerEditor extends StatefulWidget {
  const _MarkerEditor({
    required this.manifest,
    required this.marker,
    required this.x,
    required this.y,
    required this.newId,
    required this.lastCategory,
  });

  final PackManifest manifest;
  final MapMarker? marker;
  final double x;
  final double y;
  final String Function(String? category, String name) newId;
  final String? lastCategory;

  @override
  State<_MarkerEditor> createState() => _MarkerEditorState();
}

class _MarkerEditorState extends State<_MarkerEditor> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.marker?.name);
  late final _description = TextEditingController(text: widget.marker?.description);
  late final _wiki = TextEditingController(text: widget.marker?.wiki);
  late String? _category = widget.marker != null
      ? widget.marker!.category
      : (widget.manifest.category(widget.lastCategory)?.id ??
          widget.manifest.categories.firstOrNull?.id);
  late bool _trackable = widget.marker?.trackable ?? true;

  bool get _isNew => widget.marker == null;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _wiki.dispose();
    super.dispose();
  }

  MapMarker _build() {
    String? orNull(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final name = _name.text.trim();
    final base = widget.marker ??
        MapMarker(id: widget.newId(_category, name), name: name, x: widget.x, y: widget.y);
    return base.copyWith(
      name: name,
      category: () => _category,
      description: () => orNull(_description),
      wiki: () => orNull(_wiki),
      trackable: _trackable,
      // Credit goes with the text it covers.
      source: () => orNull(_description) == null ? null : widget.marker?.source,
    );
  }

  void _finish(MarkerEdit Function(MapMarker) result) {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(result(_build()));
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${widget.marker!.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop(const MarkerDeleted());
  }

  @override
  Widget build(BuildContext context) {
    final manifest = widget.manifest;
    final categoryWiki = manifest.category(_category)?.wiki;
    final canLinkWiki = manifest.wiki != null;
    return Padding(
      // Keep the form above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_isNew ? 'New marker' : 'Edit marker',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                autofocus: _isNew,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Give it a name' : null,
              ),
              const SizedBox(height: 12),
              if (manifest.categories.isNotEmpty)
                DropdownButtonFormField<String?>(
                  initialValue: _category,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
                  items: [
                    for (final (group, categories) in manifest.groupedCategories)
                      for (final c in categories)
                        DropdownMenuItem(
                          value: c.id,
                          child: Row(
                            children: [
                              CategoryBadge(category: c, size: 22),
                              const SizedBox(width: 12),
                              Expanded(child: Text('${c.name}  ·  ${group.name}',
                                  overflow: TextOverflow.ellipsis)),
                            ],
                          ),
                        ),
                  ],
                  onChanged: (v) => setState(() => _category = v),
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                minLines: 2,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Notes (shown offline)',
                  hintText: 'How to reach it, what it unlocks…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _wiki,
                decoration: InputDecoration(
                  labelText: canLinkWiki ? 'Wiki page (optional)' : 'Link URL (optional)',
                  hintText: canLinkWiki ? 'Page name, e.g. Bone Bottom' : 'https://…',
                  helperText: categoryWiki != null
                      ? 'Leave empty to use the type\'s page: $categoryWiki'
                      : null,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty || canLinkWiki || t.startsWith('http')) return null;
                  return 'This pack has no wiki set, so enter a full https:// link';
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Can be checked off'),
                subtitle: const Text('Off for things like benches that you visit but don\'t collect'),
                value: _trackable,
                onChanged: (v) => setState(() => _trackable = v),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!_isNew) ...[
                    TextButton.icon(
                      onPressed: _confirmDelete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _finish(MarkerMoveRequested.new),
                      icon: const Icon(Icons.open_with),
                      label: const Text('Move'),
                    ),
                  ],
                  FilledButton(
                    onPressed: () => _finish(MarkerSaved.new),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
