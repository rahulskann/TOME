import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../pack/pack.dart';
import '../pack/pack_store.dart';
import '../progress/progress_store.dart';
import '../search/marker_search.dart';
import '../search/search_delegate.dart';
import 'filter_sheet.dart';
import 'image_coords.dart';
import 'map_info_sheet.dart';
import 'marker_badge.dart';
import 'marker_editor.dart';
import 'marker_filter.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.pack,
    required this.filter,
    required this.progress,
  });

  final InstalledPack pack;
  final MarkerFilter filter;
  final ProgressStore progress;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  late MapDefinition _map = widget.pack.manifest.maps.first;
  bool _editing = false;

  /// Marker waiting for the user to tap its new position.
  MapMarker? _moving;

  /// Category of the last marker added, preselected for the next one.
  String? _lastCategory;

  // Replaced on every map switch: a controller carries its camera with it,
  // and a new map would inherit a position outside its bounds.
  MapController _controller = MapController();

  /// Where to put the camera when [_map] next builds (after a region swap).
  ({double x, double y, double zoom})? _startAt;

  /// Bumped on every map switch so FlutterMap rebuilds with a fresh camera.
  int _generation = 0;
  bool _switching = false;

  /// Region the user is zoomed in on but hasn't entered yet.
  MapRegion? _approaching;

  /// Zoomed past this overview's detail, about to swap to its detailed map.
  bool _approachingDetail = false;

  /// Marker just jumped to; ringed and shown even if filtered.
  String? _highlightId;

  /// Point just jumped to (a region has no marker of its own); ringed.
  (String mapId, double x, double y)? _highlightPoint;
  Timer? _highlightTimer;

  PackManifest get _manifest => widget.pack.manifest;
  List<MapMarker> get _markers => widget.pack.markers[_map.id] ?? const [];
  ImageCoords get _coords =>
      ImageCoords(maxZoom: _map.maxZoom, width: _map.imageWidth, height: _map.imageHeight);

  /// Regions of the current map whose target map exists in this pack.
  Iterable<MapRegion> get _regions => _map.regions.where((r) =>
      _manifest.map(r.map) != null || (_map.zoomsInto?.regions?.contains(r.id) ?? false));

  /// The map that zooming out of this one returns to, and how to get there.
  _ParentLink? get _parent {
    if (_manifest.parentOf(_map) case (final map, final region)) {
      return _ParentLink(map, (x, y) => region.fromChild(x, y, _map), region.zoomOffset(map, _map));
    }
    if (_manifest.zoomParentOf(_map) case (final map, final link)) {
      return _ParentLink(map, link.fromDetail, link.zoomOffset(map, _map));
    }
    return null;
  }

  MapDefinition? get _detailMap => _manifest.map(_map.zoomsInto?.map);

  bool get _hasUnlinkedMaps => _manifest.reachableMaps.length < _manifest.maps.length;

  // Zooming past these swaps maps. Child maps allow zooming out one level
  // beyond their tiles so there's room to trigger the swap back.
  double get _enterZoom => _map.maxZoom + 1.0;
  double get _exitZoom => _map.minZoom - 0.75;
  double get _minZoom => _map.minZoom - (_parent != null ? 1.0 : 0.0);

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coords = _coords;
    final view = _map.initialView;
    final start = _startAt;
    final scheme = Theme.of(context).colorScheme;
    final parent = _parent;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _editing ? scheme.tertiaryContainer : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_map.name),
            Text(_editing ? 'Editing · ${_manifest.name}' : _manifest.name,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'About this map',
            icon: const Icon(Icons.info_outline),
            onPressed: _openInfo,
          ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: _openSearch,
          ),
          // Only for packs with maps no region leads to; otherwise maps are
          // reached by tapping or zooming into regions.
          if (_hasUnlinkedMaps)
            PopupMenuButton<MapDefinition>(
              icon: const Icon(Icons.layers_outlined),
              tooltip: 'Switch map',
              onSelected: (m) => _switchTo(m),
              itemBuilder: (_) => [
                for (final m in _manifest.maps)
                  CheckedPopupMenuItem(value: m, checked: m == _map, child: Text(m.name)),
              ],
            ),
          IconButton(
            tooltip: _editing ? 'Done editing' : 'Edit markers',
            icon: Icon(_editing ? Icons.check : Icons.edit_location_alt_outlined),
            onPressed: () => setState(() {
              _editing = !_editing;
              _moving = null;
            }),
          ),
          PopupMenuButton<void Function()>(
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(value: _exportProgress, child: const Text('Export progress')),
              PopupMenuItem(value: _exportMarkers, child: const Text('Export markers')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            // A new key resets the camera when switching maps.
            key: ValueKey('${_map.id}#$_generation'),
            mapController: _controller,
            options: MapOptions(
              crs: const CrsSimple(),
              backgroundColor: scheme.surfaceContainerLowest,
              minZoom: _minZoom,
              // Allow zooming past native resolution; tiles are upscaled.
              maxZoom: _map.maxZoom + 2.0,
              initialCenter: start != null
                  ? coords.toLatLng(start.x, start.y)
                  : view != null
                      ? coords.toLatLng(view.x, view.y)
                      : coords.bounds.center,
              initialZoom: start?.zoom ?? view?.zoom ?? _map.minZoom.toDouble(),
              onPositionChanged: _onCameraMoved,
              cameraConstraint: CameraConstraint.containCenter(bounds: coords.bounds),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onLongPress: (_, point) {
                if (_editing && _moving == null) _addMarkerAt(point);
              },
              onTap: (_, point) {
                if (_moving != null) {
                  _finishMove(point);
                } else if (!_editing) {
                  final (x, y) = coords.toPixel(point);
                  final region = _regionAt(x, y);
                  final zoom = _controller.camera.zoom;
                  if (region != null) {
                    _enterRegion(region, x, y, zoom);
                  } else if (_detailMap != null &&
                      // Tapping only enters outlined covered regions, not anywhere.
                      _map.zoomsInto!.regions != null &&
                      _map.zoomsInto!.covers(_map, x, y)) {
                    _enterDetail(x, y, zoom);
                  }
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: widget.pack.tileTemplate(_map),
                tileProvider: FileTileProvider(),
                tileDimension: _map.tileSize,
                minNativeZoom: _map.minZoom,
                maxNativeZoom: _map.maxZoom,
                tileBounds: coords.bounds,
              ),
              if (_regions.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (final r in _regions)
                      Polygon(
                        points: [for (final (x, y) in r.outline) coords.toLatLng(x, y)],
                        color: scheme.primary.withValues(alpha: r == _approaching ? 0.22 : 0.06),
                        borderColor:
                            scheme.primary.withValues(alpha: r == _approaching ? 0.95 : 0.45),
                        borderStrokeWidth: r == _approaching ? 3 : 1.5,
                      ),
                  ],
                ),
              if (_highlightPoint case (final mapId, final x, final y) when mapId == _map.id)
                MarkerLayer(markers: [
                  Marker(
                    point: coords.toLatLng(x, y),
                    width: 64,
                    height: 64,
                    child: IgnorePointer(
                      child: Center(
                        child: _Highlight(
                          on: true,
                          child: Icon(Icons.place, color: scheme.primary, size: 28),
                        ),
                      ),
                    ),
                  ),
                ]),
              ListenableBuilder(
                listenable: Listenable.merge([widget.filter, widget.progress]),
                builder: (context, _) => MarkerLayer(
                  markers: [
                    for (final m in _markers)
                      if (_isShown(m))
                        Marker(
                          point: coords.toLatLng(m.x, m.y),
                          width: m.id == _highlightId ? 64 : 44,
                          height: m.id == _highlightId ? 64 : 44,
                          child: GestureDetector(
                            onTap: () => _editing ? _editMarker(m) : _tapMarker(m),
                            onLongPress: !_editing && m.trackable ? () => _toggleFound(m) : null,
                            // Larger hit area than the badge itself.
                            behavior: HitTestBehavior.opaque,
                            child: Opacity(
                              opacity: _moving?.id == m.id ? 0.35 : 1,
                              child: Center(
                                child: _Highlight(
                                  on: m.id == _highlightId,
                                  child: CategoryBadge(
                                    category: _manifest.category(m.category),
                                    found: m.trackable && widget.progress.isFound(m.id),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
          if (_manifest.categories.isNotEmpty || _markers.any((m) => m.trackable))
            Positioned(
              left: 0,
              right: 0,
              top: 8,
              child: ListenableBuilder(
                listenable: Listenable.merge([widget.filter, widget.progress]),
                builder: (context, _) => _QuickFilterBar(
                  manifest: _manifest,
                  filter: widget.filter,
                  tally: widget.progress.tally(_markers),
                  onOpenFilters: _openFilters,
                ),
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  if (_approaching case final region?)
                    _RegionHint(
                      name: region.name,
                      onOpen: () {
                        final (x, y) = coords.toPixel(_controller.camera.center);
                        _enterRegion(region, x, y, _controller.camera.zoom);
                      },
                    )
                  else if (_approachingDetail && _detailMap != null)
                    _RegionHint(
                      name: _detailMap!.name,
                      onOpen: () {
                        final (x, y) = coords.toPixel(_controller.camera.center);
                        _enterDetail(x, y, _controller.camera.zoom);
                      },
                    )
                  else if (parent != null)
                    FilledButton.tonalIcon(
                      onPressed: () => _exitToParent(_controller.camera),
                      icon: const Icon(Icons.zoom_out_map),
                      label: Text(parent.map.name),
                    ),
                  if (_editing)
                    _EditHint(
                      moving: _moving,
                      onCancelMove: () => setState(() => _moving = null),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Regions & map switching -----------------------------------------

  /// The region at (x, y) that opens a map of its own, if any.
  MapRegion? _regionAt(double x, double y) {
    for (final r in _regions.where((r) => _manifest.map(r.map) != null)) {
      if (r.contains(x, y)) return r;
    }
    return null;
  }

  void _onCameraMoved(MapCamera camera, bool hasGesture) {
    if (_switching || _moving != null) return;
    final (x, y) = _coords.toPixel(camera.center);
    final pastDetail = camera.zoom > _map.maxZoom + 0.25;
    final region = pastDetail ? _regionAt(x, y) : null;
    final detail = pastDetail &&
        region == null &&
        _detailMap != null &&
        _map.zoomsInto!.covers(_map, x, y);
    if (region != _approaching || detail != _approachingDetail) {
      setState(() {
        _approaching = region;
        _approachingDetail = detail;
      });
    }
    if (!hasGesture) return;

    if (camera.zoom >= _enterZoom && region != null) {
      _enterRegion(region, x, y, camera.zoom);
    } else if (camera.zoom >= _enterZoom && detail) {
      _enterDetail(x, y, camera.zoom);
    } else if (_parent != null && camera.zoom <= _exitZoom) {
      _exitToParent(camera);
    }
  }

  /// Continues on this overview's detailed map at the matching spot.
  void _enterDetail(double x, double y, double zoom) {
    final link = _map.zoomsInto!;
    final detail = _detailMap!;
    final (dx, dy) = link.toDetail(x, y);
    final z = (zoom + link.zoomOffset(_map, detail))
        .clamp(detail.minZoom.toDouble(), detail.maxZoom + 1.0);
    _switchTo(detail, x: dx, y: dy, zoom: z);
  }

  void _enterRegion(MapRegion region, double x, double y, double zoom) {
    final child = _manifest.map(region.map)!;
    final (cx, cy) = region.toChild(x, y, child);
    // Land inside the child's normal range so we don't bounce straight back out.
    final z = (zoom + region.zoomOffset(_map, child))
        .clamp(child.minZoom.toDouble(), child.maxZoom + 1.0);
    _switchTo(child, x: cx, y: cy, zoom: z);
  }

  void _exitToParent(MapCamera camera) {
    final parent = _parent!;
    final (x, y) = _coords.toPixel(camera.center);
    final (px, py) = parent.toParent(x, y);
    final z = (camera.zoom - parent.zoomOffset)
        .clamp(parent.map.minZoom.toDouble(), parent.map.maxZoom.toDouble());
    _switchTo(parent.map, x: px, y: py, zoom: z);
  }

  /// Markers can open another map: land on the matching spot if a region
  /// links there, otherwise at the map's starting view.
  void _tapMarker(MapMarker marker) {
    final target = _manifest.map(marker.map);
    if (target == null) {
      _showDetails(marker);
      return;
    }
    final regions = _regions.where((r) => r.map == target.id).toList();
    if (regions.isEmpty) {
      _switchTo(target);
      return;
    }
    final inside = regions.where((r) => r.contains(marker.x, marker.y)).firstOrNull;
    regions.sort((a, b) =>
        _dist(a.bounds.center, marker).compareTo(_dist(b.bounds.center, marker)));
    final region = inside ?? regions.first;
    final (cx, cy) = inside != null
        ? region.toChild(marker.x, marker.y, target)
        : region.targetIn(target).center;
    _switchTo(target, x: cx, y: cy, zoom: target.minZoom.toDouble());
  }

  static double _dist((double, double) p, MapMarker m) =>
      (p.$1 - m.x) * (p.$1 - m.x) + (p.$2 - m.y) * (p.$2 - m.y);

  void _switchTo(MapDefinition map, {double? x, double? y, double? zoom}) {
    _switching = true;
    // Deferred: this can be called from a camera callback during a frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final oldController = _controller;
      // Dispose once the old FlutterMap has been unmounted.
      WidgetsBinding.instance.addPostFrameCallback((_) => oldController.dispose());
      setState(() {
        _controller = MapController();
        _map = map;
        _startAt = x != null && y != null && zoom != null
            ? (
                x: x.clamp(0, map.imageWidth).toDouble(),
                y: y.clamp(0, map.imageHeight).toDouble(),
                zoom: zoom,
              )
            : null;
        _generation++;
        _approaching = null;
        _approachingDetail = false;
        _moving = null;
        _switching = false;
      });
    });
    // A post-frame callback waits for a frame; make sure one is coming.
    WidgetsBinding.instance.scheduleFrame();
  }

  // ---- Editing ----------------------------------------------------------

  Future<void> _addMarkerAt(LatLng point) async {
    final (x, y) = _clampToImage(_coords.toPixel(point));
    final edit = await showMarkerEditor(
      context,
      manifest: _manifest,
      x: x,
      y: y,
      newId: _newMarkerId,
      lastCategory: _lastCategory,
    );
    if (edit case MarkerSaved(:final marker)) {
      _lastCategory = marker.category;
      await _save([..._markers, marker], 'Added "${marker.name}"');
    }
  }

  Future<void> _editMarker(MapMarker marker) async {
    final edit = await showMarkerEditor(
      context,
      manifest: _manifest,
      marker: marker,
      x: marker.x,
      y: marker.y,
      newId: _newMarkerId,
    );
    switch (edit) {
      case MarkerSaved(marker: final updated):
        await _save(_replace(marker.id, updated), 'Saved "${updated.name}"');
      case MarkerDeleted():
        await _save([for (final m in _markers) if (m.id != marker.id) m],
            'Deleted "${marker.name}"');
      case MarkerMoveRequested(marker: final updated):
        // Keep any field edits made before pressing Move.
        await _save(_replace(marker.id, updated), null);
        setState(() => _moving = updated);
      case null:
        break;
    }
  }

  Future<void> _finishMove(LatLng point) async {
    final marker = _moving!;
    final (x, y) = _clampToImage(_coords.toPixel(point));
    setState(() => _moving = null);
    await _save(_replace(marker.id, marker.copyWith(x: x, y: y)), 'Moved "${marker.name}"');
  }

  List<MapMarker> _replace(String id, MapMarker updated) =>
      [for (final m in _markers) m.id == id ? updated : m];

  Future<void> _save(List<MapMarker> markers, String? message) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await saveMarkers(widget.pack, _map, markers);
      setState(() {});
      if (message != null) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  /// Marker ids must be unique across the whole pack and never reused, since
  /// progress is keyed on them.
  String _newMarkerId(String? category, String name) {
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final base = [?category, slug.replaceAll(RegExp(r'^_+|_+$'), '')]
        .where((s) => s.isNotEmpty)
        .join('_');
    final taken = {
      for (final list in widget.pack.markers.values)
        for (final m in list) m.id,
    };
    var id = base.isEmpty ? 'marker' : base;
    for (var n = 2; taken.contains(id); n++) {
      id = '${base}_$n';
    }
    return id;
  }

  (double, double) _clampToImage((double, double) p) => (
        p.$1.clamp(0, _map.imageWidth.toDouble()).roundToDouble(),
        p.$2.clamp(0, _map.imageHeight.toDouble()).roundToDouble(),
      );

  Future<void> _exportMarkers() async {
    final files = [
      for (final m in _manifest.maps)
        if (File(p.join(widget.pack.dir, m.markersFile)).existsSync())
          XFile(p.join(widget.pack.dir, m.markersFile), mimeType: 'application/json'),
    ];
    if (files.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No markers to export yet')));
      return;
    }
    await SharePlus.instance.share(ShareParams(
      files: files,
      subject: '${_manifest.name} markers',
      text: 'Markers for ${_manifest.name} v${_manifest.version}. '
          'Copy into the pack\'s markers/ folder.',
    ));
  }

  // ---- Viewing ----------------------------------------------------------

  bool _isShown(MapMarker m) =>
      m.id == _highlightId ||
      widget.filter.isVisible(m.category) &&
      // Keep a found marker visible while it's being edited or moved.
      !(widget.filter.hideFound && !_editing && m.trackable && widget.progress.isFound(m.id));

  Future<void> _openSearch() async {
    final hit = await showSearch(
      context: context,
      delegate: MarkerSearchDelegate(
        manifest: _manifest,
        markers: widget.pack.markers,
        progress: widget.progress,
      ),
    );
    if (hit != null && mounted) _jumpTo(hit);
  }

  void _jumpTo(SearchHit hit) {
    final region = hit.region;
    if (region != null) {
      _goToRegion(hit.map, region);
      return;
    }
    final m = hit.marker!;
    _centreOn(hit.map, m.x, m.y, hit.map.maxZoom.toDouble());
    _flash(markerId: m.id);
  }

  /// Opens a region's detailed map, or centres on a plain area and rings it.
  void _goToRegion(MapDefinition map, MapRegion region) {
    if (_manifest.map(region.map) case final child?) {
      final (cx, cy) = region.targetIn(child).center;
      _switchTo(child, x: cx, y: cy, zoom: child.minZoom.toDouble());
      return;
    }
    final (x, y) = region.point;
    _centreOn(map, x, y, map.maxZoom - 0.5);
    _flash(point: (map.id, x, y));
  }

  /// Opens [map] if needed and centres on (x, y), zooming in to at least [zoom].
  void _centreOn(MapDefinition map, double x, double y, double zoom) {
    if (map.id != _map.id) {
      _switchTo(map, x: x, y: y, zoom: zoom);
    } else {
      final camera = _controller.camera;
      _controller.move(_coords.toLatLng(x, y), camera.zoom > zoom ? camera.zoom : zoom);
    }
  }

  void _flash({String? markerId, (String, double, double)? point}) {
    _highlightTimer?.cancel();
    setState(() {
      _highlightId = markerId;
      _highlightPoint = point;
    });
    _highlightTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) {
        setState(() {
          _highlightId = null;
          _highlightPoint = null;
        });
      }
    });
  }

  void _openInfo() {
    showMapInfoSheet(
      context,
      manifest: _manifest,
      map: _map,
      markers: widget.pack.markers,
      progress: widget.progress,
      onGoTo: (region) => _goToRegion(_map, region),
      onOpenLink: _openLink,
    );
  }

  void _openFilters() {
    showFilterSheet(context,
        manifest: _manifest, filter: widget.filter, progress: widget.progress, markers: _markers);
  }

  void _toggleFound(MapMarker marker) {
    final nowFound = !widget.progress.isFound(marker.id);
    widget.progress.setFound(marker.id, nowFound);
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(nowFound ? 'Found: ${marker.name}' : 'Not found: ${marker.name}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => widget.progress.setFound(marker.id, !nowFound),
        ),
      ));
  }

  Future<void> _exportProgress() async {
    final tally = widget.progress.tally(widget.pack.markers.values.expand((l) => l));
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(utf8.encode(widget.progress.toJsonString()), mimeType: 'application/json')],
      fileNameOverrides: ['${_manifest.id}.progress.json'],
      subject: '${_manifest.name} progress',
      text: '${_manifest.name}: ${tally.found} of ${tally.total} found.',
    ));
  }

  void _showDetails(MapMarker marker) {
    final category = _manifest.category(marker.category);
    final links = _manifest.linksFor(marker);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      builder: (context) {
        final text = Theme.of(context).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(marker.name, style: text.titleLarge),
                if (category != null) ...[
                  const SizedBox(height: 8),
                  Chip(
                    avatar: CategoryBadge(category: category, size: 22),
                    label: Text(category.name),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
                if (marker.description != null) ...[
                  const SizedBox(height: 12),
                  Text(marker.description!, style: text.bodyLarge),
                  if (marker.source case final source?)
                    _Credit(source: source, onOpen: _openLink),
                ],
                if (marker.trackable) ...[
                  const SizedBox(height: 16),
                  ListenableBuilder(
                    listenable: widget.progress,
                    builder: (context, _) => widget.progress.isFound(marker.id)
                        ? FilledButton.icon(
                            onPressed: () => widget.progress.setFound(marker.id, false),
                            icon: const Icon(Icons.check_circle),
                            label: const Text('Found · tap to undo'),
                          )
                        : OutlinedButton.icon(
                            onPressed: () => widget.progress.setFound(marker.id, true),
                            icon: const Icon(Icons.radio_button_unchecked),
                            label: const Text('Mark as found'),
                          ),
                  ),
                ],
                if (links.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final link in links)
                        OutlinedButton.icon(
                          onPressed: () => _openLink(link),
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: Text(link.label),
                        ),
                    ],
                  ),
                ],
                if (category?.description case final about?) ...[
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    title: Text('About ${category!.name}'),
                    children: [
                      Text(about),
                      if (category.source case final source?)
                        _Credit(source: source, onOpen: _openLink),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Text('x ${marker.x.round()}, y ${marker.y.round()}', style: text.bodySmall),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openLink(MarkerLink link) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(link.url);
    final opened = uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!opened) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Couldn\'t open the link. Are you offline?')));
    }
  }
}

/// "Adapted from `source` · `license`", opening the source when tapped.
class _Credit extends StatelessWidget {
  const _Credit({required this.source, required this.onOpen});

  final ContentSource source;
  final void Function(MarkerLink) onOpen;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          decoration: source.url != null ? TextDecoration.underline : null,
        );
    final url = source.url;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        onTap: url == null ? null : () => onOpen(MarkerLink(label: source.name, url: url)),
        child: Text(source.credit, style: style),
      ),
    );
  }
}

/// A pulsing ring around a marker, to find it after a search.
class _Highlight extends StatefulWidget {
  const _Highlight({required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  State<_Highlight> createState() => _HighlightState();
}

class _HighlightState extends State<_Highlight> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.on) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Highlight old) {
    super.didUpdateWidget(old);
    if (widget.on && !_pulse.isAnimating) _pulse.repeat(reverse: true);
    if (!widget.on) _pulse.stop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.on) return widget.child;
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Container(
        width: 46 + 14 * _pulse.value,
        height: 46 + 14 * _pulse.value,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 1 - 0.6 * _pulse.value), width: 3),
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Where zooming out of a map leads.
class _ParentLink {
  const _ParentLink(this.map, this.toParent, this.zoomOffset);

  final MapDefinition map;
  final (double, double) Function(double x, double y) toParent;

  /// Added to a parent zoom when going in; subtracted coming out.
  final double zoomOffset;
}

class _RegionHint extends StatelessWidget {
  const _RegionHint({required this.name, required this.onOpen});

  final String name;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(16),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.zoom_in, color: scheme.onPrimaryContainer),
            const SizedBox(width: 8),
            Flexible(
              child: Text('Zoom in to enter $name',
                  style: TextStyle(color: scheme.onPrimaryContainer)),
            ),
            TextButton(onPressed: onOpen, child: const Text('Open')),
          ],
        ),
      ),
    );
  }
}

class _EditHint extends StatelessWidget {
  const _EditHint({required this.moving, required this.onCancelMove});

  final MapMarker? moving;
  final VoidCallback onCancelMove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = moving;
    return Material(
      color: scheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(16),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(m == null ? Icons.touch_app_outlined : Icons.open_with,
                color: scheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                m == null
                    ? 'Long-press the map to add a marker. Tap a marker to edit it.'
                    : 'Tap the new position for "${m.name}".',
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
            if (m != null) TextButton(onPressed: onCancelMove, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}

/// Filter button plus one chip per group for quick show/hide.
class _QuickFilterBar extends StatelessWidget {
  const _QuickFilterBar({
    required this.manifest,
    required this.filter,
    required this.tally,
    required this.onOpenFilters,
  });

  final PackManifest manifest;
  final MarkerFilter filter;
  final ({int found, int total}) tally;
  final VoidCallback onOpenFilters;

  @override
  Widget build(BuildContext context) {
    final hiddenCount = manifest.categories.where((c) => !filter.isVisible(c.id)).length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Badge(
              isLabelVisible: hiddenCount > 0,
              label: Text('$hiddenCount hidden'),
              child: FilledButton.tonalIcon(
                onPressed: onOpenFilters,
                icon: const Icon(Icons.tune),
                label: const Text('Filters'),
              ),
            ),
          ),
          if (tally.total > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                avatar: const Icon(Icons.check_circle_outline, size: 18),
                label: Text('${tally.found}/${tally.total}'),
                tooltip: filter.hideFound ? 'Show found' : 'Hide found',
                selected: filter.hideFound,
                showCheckmark: false,
                onSelected: (v) => filter.hideFound = v,
              ),
            ),
          for (final (group, categories) in manifest.groupedCategories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Builder(builder: (context) {
                final ids = [for (final c in categories) c.id];
                final allVisible = ids.every(filter.isVisible);
                return FilterChip(
                  label: Text(group.name),
                  selected: ids.any(filter.isVisible),
                  showCheckmark: false,
                  onSelected: (_) => filter.setVisible(ids, !allVisible),
                );
              }),
            ),
        ],
      ),
    );
  }
}
