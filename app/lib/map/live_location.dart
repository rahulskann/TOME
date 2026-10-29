import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';

import '../pack/pack.dart';
import 'image_coords.dart';

// "You are here" on maps pinned to real places (MapDefinition.geo). Off until
// the user turns it on, only while TOME is on screen, and positions are never
// saved or sent anywhere: they're drawn and dropped.

/// Where the phone is, and to within how many metres.
typedef GeoFix = ({double lat, double lng, double accuracy});

enum LocationAccess { granted, denied, deniedForever, serviceOff }

/// Where positions come from: the phone, or a fake in tests.
abstract class LocationSource {
  Future<LocationAccess> check();
  Future<LocationAccess> request();
  Stream<GeoFix> fixes();
  Future<void> openAppSettings();
  Future<void> openLocationSettings();
}

class DeviceLocation implements LocationSource {
  const DeviceLocation();

  @override
  Future<LocationAccess> check() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceOff;
    return _access(await Geolocator.checkPermission());
  }

  @override
  Future<LocationAccess> request() async => _access(await Geolocator.requestPermission());

  static LocationAccess _access(LocationPermission p) => switch (p) {
        LocationPermission.always || LocationPermission.whileInUse => LocationAccess.granted,
        LocationPermission.deniedForever => LocationAccess.deniedForever,
        _ => LocationAccess.denied,
      };

  @override
  Stream<GeoFix> fixes() => Geolocator.getPositionStream(
        locationSettings: AndroidSettings(accuracy: LocationAccuracy.high, distanceFilter: 2),
      ).map((p) => (lat: p.latitude, lng: p.longitude, accuracy: p.accuracy));

  @override
  Future<void> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();
}

/// Whether "you are here" is on, and the latest position. Listens only while
/// on and TOME is visible.
class LiveLocation extends ChangeNotifier {
  LiveLocation(this.source) {
    _lifecycle = AppLifecycleListener(onShow: _listen, onHide: _pause);
  }

  final LocationSource source;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<GeoFix>? _sub;

  bool get on => _on;
  bool _on = false;

  /// Null until the first position arrives.
  GeoFix? get fix => _fix;
  GeoFix? _fix;

  void start() {
    if (_on) return;
    _on = true;
    _listen();
    notifyListeners();
  }

  void stop() {
    if (!_on) return;
    _on = false;
    _pause();
    _fix = null;
    notifyListeners();
  }

  void _listen() {
    if (!_on || _sub != null) return;
    _sub = source.fixes().listen((f) {
      _fix = f;
      notifyListeners();
    }, onError: (Object e) => debugPrint('Location stopped: $e'));
  }

  void _pause() {
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    _pause();
    _lifecycle.dispose();
    super.dispose();
  }
}

const _earthRadius = 6371008.8;

double _rad(double deg) => deg * math.pi / 180;

/// Metres between two places, along the ground.
double distanceMetres(double lat1, double lng1, double lat2, double lng2) {
  final dLat = _rad(lat2 - lat1), dLng = _rad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadius * math.asin(math.min(1, math.sqrt(a)));
}

/// Compass direction (N, NE, E…) from the first place to the second.
String compassDirection(double lat1, double lng1, double lat2, double lng2) {
  final y = math.sin(_rad(lng2 - lng1)) * math.cos(_rad(lat2));
  final x = math.cos(_rad(lat1)) * math.sin(_rad(lat2)) -
      math.sin(_rad(lat1)) * math.cos(_rad(lat2)) * math.cos(_rad(lng2 - lng1));
  final degrees = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  return const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][((degrees + 22.5) % 360) ~/ 45];
}

/// Countries that give distances in miles.
const _milesCountries = {'US', 'GB', 'LR', 'MM'};

bool usesMiles(Locale locale) => _milesCountries.contains(locale.countryCode);

/// A rough distance for people: "350 m", "4.2 km", "2.6 mi", "300 ft".
String formatDistance(double metres, {bool miles = false}) {
  String grouped(num n) => n.round().toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  String rounded(double v, String unit) =>
      v < 10 ? '${v.toStringAsFixed(1)} $unit' : '${grouped(v)} $unit';
  if (miles) {
    final mi = metres / 1609.344;
    if (mi < 0.1) return '${grouped(math.max(10, (metres * 3.28084 / 10).round() * 10))} ft';
    return rounded(mi, 'mi');
  }
  if (metres < 1000) return '${math.max(10, (metres / 10).round() * 10)} m';
  return rounded(metres / 1000, 'km');
}

/// Draws where the user is on a pinned [map]: a dot with an accuracy ring
/// when it's in view, else an arrow at the screen edge pointing the way, with
/// the distance (tap it to go there, if it's on the map). Goes inside
/// FlutterMap's children so it follows the camera.
class YouAreHereLayer extends StatelessWidget {
  const YouAreHereLayer({
    super.key,
    required this.fix,
    required this.map,
    required this.geo,
    required this.onGoTo,
    this.miles = false,
    this.edgeInsets = const EdgeInsets.fromLTRB(84, 120, 84, 96),
  });

  final GeoFix fix;
  final MapDefinition map;
  final GeoPin geo;
  final bool miles;
  final void Function(double x, double y) onGoTo;

  /// Room kept clear of the arrow at each screen edge (filter bar, buttons).
  final EdgeInsets edgeInsets;

  static const dotColor = Color(0xFF1A73E8);

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final coords = ImageCoords(maxZoom: map.maxZoom, width: map.imageWidth, height: map.imageHeight);
    final (x, y) = geo.toPixel(fix.lat, fix.lng);
    final onMap = x >= 0 && y >= 0 && x <= map.imageWidth && y <= map.imageHeight;
    // Worked out from image pixels, not LatLng: someone far off a small map is
    // millions of pixels away, beyond what LatLng accepts. (The map never rotates.)
    final screenPerImagePixel = math.pow(2, camera.zoom - map.maxZoom).toDouble();
    final (cx, cy) = coords.toPixel(camera.center);
    final size = camera.size;
    final at = size.center(Offset.zero) + Offset((x - cx) * screenPerImagePixel, (y - cy) * screenPerImagePixel);
    if (onMap && (Offset.zero & size).contains(at)) {
      final metresPerScreenPixel = geo.metresPerPixel / screenPerImagePixel;
      return IgnorePointer(
        child: CustomPaint(
          size: size,
          painter: _DotPainter(at: at, accuracyRadius: fix.accuracy / metresPerScreenPixel),
        ),
      );
    }

    // Off screen (or off the map): an arrow on the way from the centre.
    final centre = size.center(Offset.zero);
    final dir = at - centre;
    final halfW = math.max(1.0, size.width / 2 - edgeInsets.horizontal / 2);
    final halfH = math.max(1.0, size.height / 2 - edgeInsets.vertical / 2);
    final t = math.min(1.0, math.min(
        dir.dx == 0 ? double.infinity : halfW / dir.dx.abs(),
        dir.dy == 0 ? double.infinity : halfH / dir.dy.abs()));
    final shift = Offset((edgeInsets.left - edgeInsets.right) / 2, (edgeInsets.top - edgeInsets.bottom) / 2);
    final anchor = centre + shift + dir * t;

    final (clat, clng) = geo.toLatLng(cx, cy);
    // Where the user is, seen from the middle of the screen; the arrow points there.
    final away = '${formatDistance(distanceMetres(clat, clng, fix.lat, fix.lng), miles: miles)} '
        '${compassDirection(clat, clng, fix.lat, fix.lng)}';
    final label = onMap ? 'You\'re about $away' : 'Off this map · you\'re about $away';
    return SizedBox.fromSize(
      size: size,
      child: CustomSingleChildLayout(
        delegate: _CentredOnScreen(anchor),
        child: _EdgeArrow(
          angle: math.atan2(dir.dy, dir.dx),
          label: label,
          onTap: onMap ? () => onGoTo(x, y) : null,
        ),
      ),
    );
  }
}

/// Centres the arrow on its anchor, nudged inwards so it's never cut off.
class _CentredOnScreen extends SingleChildLayoutDelegate {
  const _CentredOnScreen(this.anchor);

  final Offset anchor;
  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen().deflate(const EdgeInsets.all(_margin));

  @override
  Offset getPositionForChild(Size size, Size child) => Offset(
        (anchor.dx - child.width / 2).clamp(_margin, math.max(_margin, size.width - child.width - _margin)),
        (anchor.dy - child.height / 2).clamp(_margin, math.max(_margin, size.height - child.height - _margin)),
      );

  @override
  bool shouldRelayout(_CentredOnScreen old) => old.anchor != anchor;
}

class _DotPainter extends CustomPainter {
  const _DotPainter({required this.at, required this.accuracyRadius});

  final Offset at;
  final double accuracyRadius;

  @override
  void paint(Canvas canvas, Size size) {
    const blue = YouAreHereLayer.dotColor;
    if (accuracyRadius > 10) {
      canvas.drawCircle(at, accuracyRadius, Paint()..color = blue.withValues(alpha: 0.12));
      canvas.drawCircle(
          at,
          accuracyRadius,
          Paint()
            ..color = blue.withValues(alpha: 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }
    canvas.drawCircle(at, 11, Paint()..color = Colors.black.withValues(alpha: 0.18));
    canvas.drawCircle(at, 10, Paint()..color = Colors.white);
    canvas.drawCircle(at, 7, Paint()..color = blue);
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.at != at || old.accuracyRadius != accuracyRadius;
}

class _EdgeArrow extends StatelessWidget {
  const _EdgeArrow({required this.angle, required this.label, required this.onTap});

  /// Radians, screen convention (0 = right, clockwise).
  final double angle;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.rotate(
                angle: angle,
                child: const Icon(Icons.arrow_forward, size: 20, color: YouAreHereLayer.dotColor),
              ),
              const SizedBox(width: 6),
              Flexible(child: Text(label, style: Theme.of(context).textTheme.labelMedium)),
            ],
          ),
        ),
      ),
    );
  }
}
