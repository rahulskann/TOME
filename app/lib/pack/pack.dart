// Models for the pack format described in docs/pack-format.md.
import 'dart:math' as math;
import 'dart:ui' show Color;

/// The newest `schemaVersion` this build of the app understands.
const int supportedSchemaVersion = 1;

class PackManifest {
  const PackManifest({
    required this.schemaVersion,
    required this.id,
    required this.name,
    required this.version,
    required this.maps,
    this.game,
    this.author,
    this.description,
    this.wiki,
    this.categoryGroups = const [],
    this.categories = const [],
  });

  final int schemaVersion;
  final String id;
  final String name;
  final String version;
  final String? game;
  final String? author;
  final String? description;

  /// Base URL that `wiki` page names are appended to, e.g.
  /// `https://hollowknight.wiki/w/`.
  final String? wiki;
  final List<CategoryGroup> categoryGroups;
  final List<MarkerCategory> categories;
  final List<MapDefinition> maps;

  factory PackManifest.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'] as int;
    if (schemaVersion > supportedSchemaVersion) {
      throw FormatException(
          'Pack uses schemaVersion $schemaVersion; this app supports up to '
          '$supportedSchemaVersion. Update TOME to open it.');
    }
    return PackManifest(
      schemaVersion: schemaVersion,
      id: json['id'] as String,
      name: json['name'] as String,
      version: json['version'] as String,
      game: json['game'] as String?,
      author: json['author'] as String?,
      description: json['description'] as String?,
      wiki: json['wiki'] as String?,
      categoryGroups: [
        for (final g in (json['categoryGroups'] as List? ?? const []))
          CategoryGroup.fromJson(g as Map<String, dynamic>),
      ],
      categories: [
        for (final c in (json['categories'] as List? ?? const []))
          MarkerCategory.fromJson(c as Map<String, dynamic>),
      ],
      maps: [
        for (final m in json['maps'] as List)
          MapDefinition.fromJson(m as Map<String, dynamic>),
      ],
    );
  }

  MarkerCategory? category(String? id) {
    if (id == null) return null;
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  MapDefinition? map(String? id) {
    for (final m in maps) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The map with a region that opens [child], used to zoom back out.
  (MapDefinition, MapRegion)? parentOf(MapDefinition child) {
    for (final m in maps) {
      for (final r in m.regions) {
        if (r.map == child.id && m.id != child.id) return (m, r);
      }
    }
    return null;
  }

  /// Markers that belong to [region] of [map]: the part of its detailed map
  /// it stands for, or the markers inside its outline. Empty for point regions.
  Iterable<MapMarker> markersIn(
      MapDefinition map, MapRegion region, Map<String, List<MapMarker>> markers) {
    final child = this.map(region.map);
    if (child != null) {
      final t = region.targetIn(child);
      return (markers[child.id] ?? const []).where((m) =>
          m.x >= t.x && m.x <= t.x + t.width && m.y >= t.y && m.y <= t.y + t.height);
    }
    return (markers[map.id] ?? const []).where((m) => region.contains(m.x, m.y));
  }

  /// Links to show for [marker]: its own wiki page, else its category's,
  /// followed by any explicit links. Content stays offline; these only open
  /// when tapped.
  List<MarkerLink> linksFor(MapMarker marker) {
    final page = marker.wiki ?? category(marker.category)?.wiki;
    final url = page == null ? null : wikiUrl(page);
    return [
      if (url != null) MarkerLink(label: 'Wiki: $page', url: url),
      ...marker.links,
    ];
  }

  /// Resolves a wiki page name against [wiki]. Full URLs pass through.
  String? wikiUrl(String page) {
    if (page.startsWith('https://') || page.startsWith('http://')) return page;
    final base = wiki;
    if (base == null) return null;
    return base + Uri.encodeComponent(page.replaceAll(' ', '_'));
  }

  /// Categories arranged by group, in declaration order. Categories with no
  /// group, or an undeclared one, are collected into a trailing "Other" group.
  List<(CategoryGroup, List<MarkerCategory>)> get groupedCategories {
    final known = {for (final g in categoryGroups) g.id};
    final result = [
      for (final g in categoryGroups)
        (g, [for (final c in categories) if (c.group == g.id) c]),
    ];
    final other = [
      for (final c in categories)
        if (c.group == null || !known.contains(c.group)) c,
    ];
    if (other.isNotEmpty) {
      result.add((CategoryGroup(id: '', name: result.isEmpty ? 'Markers' : 'Other'), other));
    }
    return [for (final r in result) if (r.$2.isNotEmpty) r];
  }
}

/// A heading that categories are filed under, e.g. "Collectibles".
class CategoryGroup {
  const CategoryGroup({required this.id, required this.name});

  final String id;
  final String name;

  factory CategoryGroup.fromJson(Map<String, dynamic> json) => CategoryGroup(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

class MarkerCategory {
  const MarkerCategory({
    required this.id,
    required this.name,
    this.group,
    this.color,
    this.icon,
    this.wiki,
    this.description,
    this.source,
  });

  final String id;
  final String name;

  /// Id of a [CategoryGroup].
  final String? group;
  final Color? color;

  /// Name from the built-in icon set (see `category_icons.dart`).
  final String? icon;

  /// Wiki page for markers of this category that don't name their own.
  final String? wiki;

  /// General notes shown with every marker of this category, e.g. what
  /// benches do. Stored offline.
  final String? description;

  /// Where [description] came from, for credit.
  final ContentSource? source;

  factory MarkerCategory.fromJson(Map<String, dynamic> json) => MarkerCategory(
        id: json['id'] as String,
        name: json['name'] as String,
        group: json['group'] as String?,
        color: parseHexColor(json['color'] as String?),
        icon: json['icon'] as String?,
        wiki: json['wiki'] as String?,
        description: json['description'] as String?,
        source: ContentSource.fromJsonOrNull(json['source']),
      );
}

class MapDefinition {
  const MapDefinition({
    required this.id,
    required this.name,
    required this.imageWidth,
    required this.imageHeight,
    required this.tileSize,
    required this.minZoom,
    required this.maxZoom,
    required this.tilesArchive,
    required this.tilesPath,
    this.archiveBytes,
    this.markersPath,
    this.initialView,
    this.regions = const [],
    this.description,
    this.source,
    this.wiki,
  });

  final String id;
  final String name;
  final int imageWidth;
  final int imageHeight;
  final int tileSize;
  final int minZoom;

  /// Zoom level at which one tile pixel is one image pixel.
  final int maxZoom;
  final String tilesArchive;

  /// Size of [tilesArchive] in bytes, if the pack declares it.
  final int? archiveBytes;

  /// Template of tile paths inside the archive, e.g. `{z}/{x}/{y}.png`.
  final String tilesPath;
  final String? markersPath;
  final InitialView? initialView;

  /// Named areas of this map: listed in its info sheet and search, and
  /// opening a more detailed map when they link one.
  final List<MapRegion> regions;

  /// About this map, shown in its info sheet. Stored offline.
  final String? description;
  final ContentSource? source;

  /// Wiki page for this map (see [PackManifest.wiki]).
  final String? wiki;

  /// Where this map's markers live, relative to the pack root. Maps without
  /// a `markers` entry get a conventional path so edits have somewhere to go.
  String get markersFile => markersPath ?? 'markers/$id.json';

  factory MapDefinition.fromJson(Map<String, dynamic> json) {
    final image = json['image'] as Map<String, dynamic>;
    final tiles = json['tiles'] as Map<String, dynamic>;
    final view = json['initialView'] as Map<String, dynamic>?;
    return MapDefinition(
      id: json['id'] as String,
      name: json['name'] as String,
      imageWidth: image['width'] as int,
      imageHeight: image['height'] as int,
      tileSize: json['tileSize'] as int? ?? 256,
      minZoom: json['minZoom'] as int? ?? 0,
      maxZoom: json['maxZoom'] as int,
      tilesArchive: tiles['archive'] as String,
      archiveBytes: tiles['archiveBytes'] as int?,
      tilesPath: tiles['path'] as String,
      markersPath: json['markers'] as String?,
      initialView: view == null ? null : InitialView.fromJson(view),
      regions: [
        for (final r in (json['regions'] as List? ?? const []))
          MapRegion.fromJson(r as Map<String, dynamic>),
      ],
      description: json['description'] as String?,
      source: ContentSource.fromJsonOrNull(json['source']),
      wiki: json['wiki'] as String?,
    );
  }
}

/// A named area of a map: a region of a world overview, or a place within
/// a region map.
///
/// Every region has a position: an [outline] (a polygon in this map's pixels)
/// and/or a label point ([x], [y]). A region that names a [map] opens that
/// more detailed map when tapped or zoomed into; it needs an outline, and
/// [target] is the rectangle of the child map it corresponds to (the whole
/// child image if omitted), so a point inside the outline can be carried
/// across to the child and back. The two maps needn't share geometry: a
/// stylised overview works fine.
class MapRegion {
  MapRegion({
    required this.id,
    required this.name,
    this.map,
    List<(double, double)> outline = const [],
    double? x,
    double? y,
    this.target,
    this.wiki,
    this.description,
    this.source,
  })  : outline = List.unmodifiable(outline),
        _x = x,
        _y = y {
    if (outline.isNotEmpty && outline.length < 3) {
      throw FormatException('Region $id: an outline needs at least 3 points');
    }
    if (outline.isEmpty && (x == null || y == null)) {
      throw FormatException('Region $id needs an outline or an x/y point');
    }
    if (map != null && outline.isEmpty) {
      throw FormatException('Region $id opens a map, so it needs an outline');
    }
  }

  final String id;
  final String name;

  /// Id of the map this region opens, if any.
  final String? map;
  final List<(double, double)> outline;
  final double? _x;
  final double? _y;
  final PixelRect? target;
  final String? wiki;
  final String? description;
  final ContentSource? source;

  factory MapRegion.fromJson(Map<String, dynamic> json) => MapRegion(
        id: json['id'] as String,
        name: json['name'] as String,
        map: json['map'] as String?,
        outline: [
          for (final p in (json['outline'] as List? ?? const []).cast<List<dynamic>>())
            ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
        ],
        x: (json['x'] as num?)?.toDouble(),
        y: (json['y'] as num?)?.toDouble(),
        target: json['target'] == null
            ? null
            : PixelRect.fromJson(json['target'] as Map<String, dynamic>),
        wiki: json['wiki'] as String?,
        description: json['description'] as String?,
        source: ContentSource.fromJsonOrNull(json['source']),
      );

  /// Where to centre the camera for this region.
  (double, double) get point =>
      _x != null && _y != null ? (_x, _y) : bounds.center;

  /// Bounding box of the outline (a point-sized box for point regions).
  late final PixelRect bounds = () {
    if (outline.isEmpty) return PixelRect(_x!, _y!, 0, 0);
    var (minX, minY, maxX, maxY) = (double.infinity, double.infinity, -double.infinity, -double.infinity);
    for (final (x, y) in outline) {
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
    }
    return PixelRect(minX, minY, maxX - minX, maxY - minY);
  }();

  /// Even-odd ray casting. Point regions contain nothing.
  bool contains(double x, double y) {
    var inside = false;
    for (var i = 0, j = outline.length - 1; i < outline.length; j = i++) {
      final (xi, yi) = outline[i];
      final (xj, yj) = outline[j];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// The part of [child] this region stands for.
  PixelRect targetIn(MapDefinition child) =>
      target ?? PixelRect(0, 0, child.imageWidth.toDouble(), child.imageHeight.toDouble());

  /// Carries a point in this region's [bounds] to the matching point of [child].
  (double, double) toChild(double x, double y, MapDefinition child) =>
      bounds.mapPointTo(x, y, targetIn(child));

  /// Inverse of [toChild].
  (double, double) fromChild(double x, double y, MapDefinition child) =>
      targetIn(child).mapPointTo(x, y, bounds);

  /// Zoom offset that keeps the region roughly the same size on screen when
  /// swapping from [parent] to [child] (add it going in, subtract coming out).
  double zoomOffset(MapDefinition parent, MapDefinition child) {
    final t = targetIn(child);
    final scale = math.max(bounds.width, bounds.height) / math.max(t.width, t.height);
    return (child.maxZoom - parent.maxZoom) + math.log(scale) / math.ln2;
  }
}

/// An axis-aligned rectangle in image pixels.
class PixelRect {
  const PixelRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  factory PixelRect.fromJson(Map<String, dynamic> json) => PixelRect(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
        (json['width'] as num).toDouble(),
        (json['height'] as num).toDouble(),
      );

  (double, double) get center => (x + width / 2, y + height / 2);

  (double, double) mapPointTo(double px, double py, PixelRect other) => (
        other.x + (px - x) / width * other.width,
        other.y + (py - y) / height * other.height,
      );
}

/// Starting camera position, in image pixels.
class InitialView {
  const InitialView({required this.x, required this.y, this.zoom});

  final double x;
  final double y;
  final double? zoom;

  factory InitialView.fromJson(Map<String, dynamic> json) => InitialView(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        zoom: (json['zoom'] as num?)?.toDouble(),
      );
}

class MapMarker {
  const MapMarker({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    this.category,
    this.description,
    this.trackable = true,
    this.wiki,
    this.links = const [],
    this.map,
    this.source,
    this.extra = const {},
  });

  final String id;
  final String name;

  /// Pixel position on the full-resolution image; origin top-left, y down.
  final double x;
  final double y;
  final String? category;
  final String? description;
  final bool trackable;

  /// Wiki page name (see [PackManifest.wiki]) or a full URL.
  final String? wiki;
  final List<MarkerLink> links;

  /// Id of a map this marker opens when tapped (a region, a door, a lift).
  final String? map;

  /// Where [description] came from, for credit.
  final ContentSource? source;

  /// Fields this version of the app doesn't know, kept so saving an edited
  /// marker doesn't drop them.
  final Map<String, dynamic> extra;

  static const _known = {
    'id', 'name', 'x', 'y', 'category', 'description', 'trackable', 'wiki', 'links', 'map',
    'source',
  };

  factory MapMarker.fromJson(Map<String, dynamic> json) => MapMarker(
        id: json['id'] as String,
        name: json['name'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        category: json['category'] as String?,
        description: json['description'] as String?,
        trackable: json['trackable'] as bool? ?? true,
        wiki: json['wiki'] as String?,
        map: json['map'] as String?,
        source: ContentSource.fromJsonOrNull(json['source']),
        links: [
          for (final l in (json['links'] as List? ?? const []))
            MarkerLink.fromJson(l as Map<String, dynamic>),
        ],
        extra: {
          for (final e in json.entries)
            if (!_known.contains(e.key)) e.key: e.value,
        },
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (category != null) 'category': category,
        'x': _num(x),
        'y': _num(y),
        if (description != null) 'description': description,
        if (wiki != null) 'wiki': wiki,
        if (links.isNotEmpty) 'links': [for (final l in links) l.toJson()],
        if (map != null) 'map': map,
        if (source != null) 'source': source!.toJson(),
        if (!trackable) 'trackable': false,
        ...extra,
      };

  MapMarker copyWith({
    String? name,
    double? x,
    double? y,
    String? Function()? category,
    String? Function()? description,
    bool? trackable,
    String? Function()? wiki,
    ContentSource? Function()? source,
  }) =>
      MapMarker(
        id: id,
        name: name ?? this.name,
        x: x ?? this.x,
        y: y ?? this.y,
        category: category != null ? category() : this.category,
        description: description != null ? description() : this.description,
        trackable: trackable ?? this.trackable,
        wiki: wiki != null ? wiki() : this.wiki,
        links: links,
        map: map,
        source: source != null ? source() : this.source,
        extra: extra,
      );

  static List<MapMarker> listFromJson(List<dynamic> json) => [
        for (final m in json) MapMarker.fromJson(m as Map<String, dynamic>),
      ];

  // Whole pixels are written as ints so hand-edited files stay tidy.
  static num _num(double v) => v == v.roundToDouble() ? v.round() : v;
}

/// Credit for text adapted from elsewhere, e.g. a CC BY-SA wiki page.
class ContentSource {
  const ContentSource({required this.name, this.url, this.license});

  /// Human-readable source, e.g. "Hollow Knight Wiki: Bone Bottom".
  final String name;
  final String? url;

  /// e.g. "CC BY-SA 3.0".
  final String? license;

  static ContentSource? fromJsonOrNull(Object? json) => json is Map<String, dynamic>
      ? ContentSource(
          name: json['name'] as String,
          url: json['url'] as String?,
          license: json['license'] as String?,
        )
      : null;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (url != null) 'url': url,
        if (license != null) 'license': license,
      };

  /// "Adapted from `name` · `license`".
  String get credit => 'Adapted from $name${license != null ? ' · $license' : ''}';
}

class MarkerLink {
  const MarkerLink({required this.label, required this.url});

  final String label;
  final String url;

  factory MarkerLink.fromJson(Map<String, dynamic> json) =>
      MarkerLink(label: json['label'] as String, url: json['url'] as String);

  Map<String, dynamic> toJson() => {'label': label, 'url': url};
}

/// Parses `#RRGGBB` or `#AARRGGBB`; returns null for anything else.
Color? parseHexColor(String? hex) {
  if (hex == null || !hex.startsWith('#')) return null;
  final digits = hex.substring(1);
  final value = int.tryParse(digits, radix: 16);
  if (value == null) return null;
  return switch (digits.length) {
    6 => Color(0xFF000000 | value),
    8 => Color(value),
    _ => null,
  };
}
