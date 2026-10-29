import 'dart:math' as math;
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:tome/map/live_location.dart';
import 'package:tome/pack/pack.dart';

void main() {
  group('GeoPin', () {
    // A north-up map, 2 px per metre-ish: corners pinned.
    final northUp = GeoPin([(0, 0, 45.53, -122.70), (2000, 1000, 45.52, -122.68)]);

    test('the pinned points land where they were pinned, and back', () {
      for (final (x, y, lat, lng) in northUp.points) {
        final (px, py) = northUp.toPixel(lat, lng);
        expect(px, closeTo(x, 1e-6));
        expect(py, closeTo(y, 1e-6));
        final (la, ln) = northUp.toLatLng(x, y);
        expect(la, closeTo(lat, 1e-9));
        expect(ln, closeTo(lng, 1e-9));
      }
    });

    test('north is up: further north is higher on the image, east is right', () {
      final (x0, y0) = northUp.toPixel(45.525, -122.69);
      final (_, yN) = northUp.toPixel(45.526, -122.69);
      final (xE, _) = northUp.toPixel(45.525, -122.689);
      expect(yN, lessThan(y0));
      expect(xE, greaterThan(x0));
    });

    test('a rotated map: two points are enough', () {
      // The image is turned a quarter: image "up" (smaller y) points east.
      final turned = GeoPin([(100, 100, 45.5, -122.6), (100, 0, 45.5, -122.59)]);
      final (x, y) = turned.toPixel(45.51, -122.6); // north of the first point
      expect(y, closeTo(100, 1e-3), reason: 'north runs along the image x axis');
      expect(x, lessThan(100));
      expect(turned.metresPerPixel, closeTo(0.01 * 111320 * math.cos(45.5 * math.pi / 180) / 100, 0.05));
    });

    test('more points: the best fit', () {
      // A third point that agrees changes nothing; one a little off is averaged in.
      final (lat, lng) = northUp.toLatLng(2000, 0);
      final agreeing = GeoPin([...northUp.points, (2000, 0, lat, lng)]);
      final off = GeoPin([...northUp.points, (2010, 0, lat, lng)]);
      final (x, y) = northUp.toPixel(45.525, -122.69);
      final (ax, ay) = agreeing.toPixel(45.525, -122.69);
      final (ox, oy) = off.toPixel(45.525, -122.69);
      expect(ax, closeTo(x, 0.01));
      expect(ay, closeTo(y, 0.01));
      expect((ox - x).abs() + (oy - y).abs(), inInclusiveRange(0.1, 10));
    });

    test('needs two different places', () {
      expect(() => GeoPin([(0, 0, 45, -122)]), throwsFormatException);
      expect(() => GeoPin([(0, 0, 45, -122), (10, 10, 45, -122)]), throwsFormatException);
      expect(() => GeoPin([(5, 5, 45, -122), (5, 5, 46, -122)]), throwsFormatException);
    });

    test('maps read it from pack.json', () {
      final map = MapDefinition.fromJson({
        'id': 'park',
        'name': 'Park',
        'image': {'width': 2000, 'height': 1000},
        'maxZoom': 3,
        'tiles': {'archive': 'a.zip', 'path': '{z}/{x}/{y}.png'},
        'geo': {
          'points': [
            [0, 0, 45.53, -122.70],
            [2000, 1000, 45.52, -122.68],
          ],
        },
      });
      expect(map.geo!.points, hasLength(2));
    });
  });

  test('marker photos round-trip and can be cleared', () {
    final m = MapMarker.fromJson({'id': 'a', 'name': 'A', 'x': 1, 'y': 2, 'photo': 'photos/a.jpg'});
    expect(m.photo, 'photos/a.jpg');
    expect(m.toJson()['photo'], 'photos/a.jpg');
    expect(m.extra, isEmpty);
    expect(m.copyWith(photo: () => null).toJson().containsKey('photo'), isFalse);
  });

  group('distances', () {
    test('distance and direction', () {
      // One degree of latitude is about 111 km.
      expect(distanceMetres(45, -122, 46, -122), closeTo(111195, 100));
      expect(compassDirection(45, -122, 46, -122), 'N');
      expect(compassDirection(45, -122, 45, -121), 'E');
      expect(compassDirection(45, -122, 44, -123), 'SW');
      expect(compassDirection(45, -122, 45.7, -121), 'NE');
    });

    test('reads like a person would say it', () {
      expect(formatDistance(4), '10 m');
      expect(formatDistance(347), '350 m');
      expect(formatDistance(4230), '4.2 km');
      expect(formatDistance(42300), '42 km');
      expect(formatDistance(11000000), '11,000 km');
      expect(formatDistance(90, miles: true), '300 ft');
      expect(formatDistance(4200, miles: true), '2.6 mi');
      expect(formatDistance(42000, miles: true), '26 mi');
    });

    test('miles where people use them', () {
      expect(usesMiles(const Locale('en', 'US')), isTrue);
      expect(usesMiles(const Locale('en', 'GB')), isTrue);
      expect(usesMiles(const Locale('en', 'CA')), isFalse);
      expect(usesMiles(const Locale('fr')), isFalse);
    });
  });
}
