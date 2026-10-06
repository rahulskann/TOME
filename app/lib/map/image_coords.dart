import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Converts between image pixels (what pack authors write) and the [LatLng]
/// values flutter_map uses with [CrsSimple].
///
/// [CrsSimple] maps a coordinate to `coord * 256 * 2^zoom` screen pixels, and
/// at the pack's `maxZoom` one screen pixel is one image pixel, so:
///
///     lng =  px / (256 * 2^maxZoom)
///     lat = -py / (256 * 2^maxZoom)   (CrsSimple's latitude points up)
///
/// The slicer picks the smallest `maxZoom` that fits the image in one tile at
/// zoom 0, so coordinates stay within about ±1 — well inside latlong2's ±90.
class ImageCoords {
  ImageCoords({required this.maxZoom, required this.width, required this.height})
      : _unitsPerPixel = 1 / (256 * math.pow(2, maxZoom));

  final int maxZoom;
  final int width;
  final int height;
  final double _unitsPerPixel;

  LatLng toLatLng(double x, double y) =>
      LatLng(-y * _unitsPerPixel, x * _unitsPerPixel);

  /// Inverse of [toLatLng]: returns `(x, y)` in image pixels.
  (double, double) toPixel(LatLng point) =>
      (point.longitude / _unitsPerPixel, -point.latitude / _unitsPerPixel);

  /// The whole image, used to keep the camera and tile requests on the map.
  LatLngBounds get bounds => LatLngBounds(
      toLatLng(0, 0), toLatLng(width.toDouble(), height.toDouble()));
}
