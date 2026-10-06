import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:tome/pack/pack_installer.dart';

const raw = 'https://raw.githubusercontent.com/a/maps';
const release = 'https://github.com/a/maps/releases/download/v1/world-tiles.zip';

Uint8List tilesZip() {
  final archive = Archive()
    ..add(ArchiveFile.bytes('0/0/0.png', Uint8List.fromList(List.filled(500, 7))))
    ..add(ArchiveFile.bytes('1/0/0.png', Uint8List.fromList(List.filled(500, 9))));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String manifest({String version = '1.0.0', int? bytes}) => jsonEncode({
      'schemaVersion': 1,
      'id': 'a.pack',
      'name': 'A Pack',
      'version': version,
      'maps': [
        {
          'id': 'world',
          'name': 'World',
          'image': {'width': 256, 'height': 256},
          'maxZoom': 1,
          'tiles': {'archive': release, 'path': '{z}/{x}/{y}.png', 'archiveBytes': ?bytes},
          'markers': 'markers/world.json',
        },
      ],
    });

const markersJson = '[{"id": "m1", "name": "M1", "x": 10, "y": 10}]';

/// A fake GitHub: pack.json only on `master` under silksong/, a release zip
/// that honours Range requests, and a markers file.
class FakeServer {
  FakeServer({this.version = '1.0.0'});

  String version;
  final zip = tilesZip();
  final requests = <http.BaseRequest>[];
  bool failZip = false;

  late final client = MockClient((req) async {
    requests.add(req);
    final url = req.url.toString();
    if (url == '$raw/master/silksong/pack.json') {
      return http.Response(manifest(version: version, bytes: zip.length), 200);
    }
    if (url == '$raw/master/silksong/markers/world.json') return http.Response(markersJson, 200);
    if (url == release) {
      if (failZip) return http.Response('boom', 500);
      final range = req.headers['range'];
      if (range != null) {
        final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        return http.Response.bytes(zip.sublist(from), 206);
      }
      return http.Response.bytes(zip, 200);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('tome_install_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('falls back from main to master and parses the manifest', () async {
    final server = FakeServer();
    final remote = await fetchRemotePack('a/maps/silksong', client: server.client);
    expect(remote.folder.toString(), '$raw/master/silksong/');
    expect(remote.manifest.name, 'A Pack');
    expect(remote.downloadBytes, server.zip.length);
    expect(server.requests.first.url.toString(), '$raw/main/silksong/pack.json');
  });

  test('explains a missing pack and a bad link', () async {
    final server = FakeServer();
    expect(() => fetchRemotePack('a/maps/nothing-here', client: server.client),
        throwsA(isA<PackFetchException>()));
    expect(() => fetchRemotePack('not a link', client: server.client),
        throwsA(isA<PackFetchException>()));
  });

  test('installs tiles, markers, source and snapshot; reports progress', () async {
    final server = FakeServer();
    final remote = await fetchRemotePack('a/maps/silksong', client: server.client);
    final progress = <InstallProgress>[];
    final pack = await installRemotePack(remote,
        client: server.client, root: root, onProgress: progress.add);

    expect(pack.manifest.id, 'a.pack');
    expect(pack.markers['world']!.single.id, 'm1');
    expect(File(p.join(pack.dir, 'world', 'tiles', '1', '0', '0.png')).existsSync(), isTrue);
    expect(await installedFrom(pack), 'a/maps/silksong');
    expect(File(p.join(pack.dir, '.installed', 'markers', 'world.json')).existsSync(), isTrue);
    expect(progress.map((e) => e.fraction).whereType<double>().last, 1.0);
    expect(Directory(p.join(root.path, '.downloads', 'a.pack')).existsSync(), isFalse);
    expect(root.listSync().map((e) => p.basename(e.path)), isNot(contains(startsWith('.staging'))));
  });

  test('resumes a partial download with a Range request', () async {
    final server = FakeServer();
    final remote = await fetchRemotePack('a/maps/silksong', client: server.client);
    final part = File(p.join(root.path, '.downloads', 'a.pack', 'world-1.0.0.zip.part'));
    part.createSync(recursive: true);
    part.writeAsBytesSync(server.zip.sublist(0, 100));

    final pack = await installRemotePack(remote, client: server.client, root: root);
    final zipRequest = server.requests.lastWhere((r) => r.url.toString() == release);
    expect(zipRequest.headers['range'], 'bytes=100-');
    expect(File(p.join(pack.dir, 'world', 'tiles', '0', '0', '0.png')).lengthSync(), 500);
  });

  test('a failed download leaves the installed version untouched', () async {
    final server = FakeServer();
    final v1 = await installRemotePack(
        await fetchRemotePack('a/maps/silksong', client: server.client),
        client: server.client, root: root);

    server
      ..version = '2.0.0'
      ..failZip = true;
    final update = await checkForUpdate(v1, client: server.client);
    expect(update!.manifest.version, '2.0.0');
    await expectLater(installRemotePack(update, client: server.client, root: root),
        throwsA(isA<PackFetchException>()));

    final still = jsonDecode(File(p.join(v1.dir, 'pack.json')).readAsStringSync());
    expect(still['version'], '1.0.0');
    expect(File(p.join(v1.dir, 'world', 'tiles', '0', '0', '0.png')).existsSync(), isTrue);
  });

  test('no update when the version matches', () async {
    final server = FakeServer();
    final pack = await installRemotePack(
        await fetchRemotePack('a/maps/silksong', client: server.client),
        client: server.client, root: root);
    expect(await checkForUpdate(pack, client: server.client), isNull);
  });

  test('detects marker edits made on the device', () async {
    final server = FakeServer();
    final pack = await installRemotePack(
        await fetchRemotePack('a/maps/silksong', client: server.client),
        client: server.client, root: root);
    expect(await hasLocalMarkerEdits(pack), isFalse);
    File(p.join(pack.dir, 'markers', 'world.json')).writeAsStringSync('[]');
    expect(await hasLocalMarkerEdits(pack), isTrue);
  });
}
