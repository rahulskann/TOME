import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:tome/pack/pack.dart';
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
      'categories': [
        {'id': 'shard', 'name': 'Shard', 'icon': 'gem', 'iconImage': 'icons/shard.png'},
        {'id': 'gone', 'name': 'Gone', 'iconImage': 'icons/missing.png'},
        {'id': 'bad', 'name': 'Bad', 'iconImage': '../../escape.png'},
      ],
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
    if (url == '$raw/master/silksong/icons/shard.png') return http.Response.bytes([1, 2, 3], 200);
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

  test('downloads custom icons; skips missing and unsafe ones', () async {
    final server = FakeServer();
    final remote = await fetchRemotePack('a/maps/silksong', client: server.client);
    final pack = await installRemotePack(remote, client: server.client, root: root);

    final shard = pack.manifest.category('shard')!;
    expect(shard.iconFile, p.join(pack.dir, 'icons', 'shard.png'));
    expect(File(shard.iconFile!).readAsBytesSync(), [1, 2, 3]);
    // Missing: the install still succeeds and the badge falls back to the built-in icon.
    expect(File(pack.manifest.category('gone')!.iconFile!).existsSync(), isFalse);
    // Unsafe paths are dropped when parsing, so nothing is ever fetched or written for them.
    expect(pack.manifest.category('bad')!.iconImage, isNull);
    expect(server.requests.map((r) => r.url.path), isNot(contains(endsWith('escape.png'))));
  });

  test('fetches icons missing from an already-installed pack', () async {
    final server = FakeServer();
    final remote = await fetchRemotePack('a/maps/silksong', client: server.client);
    final pack = await installRemotePack(remote, client: server.client, root: root);
    final icon = File(pack.manifest.category('shard')!.iconFile!);
    icon.deleteSync(); // as if installed by an app that didn't know about icons

    expect(await fetchMissingIcons(pack, client: server.client), 1);
    expect(icon.readAsBytesSync(), [1, 2, 3]);
    // The one that's missing on the server too is tried, not fatal; nothing else is fetched.
    expect(await fetchMissingIcons(pack, client: server.client), 0);
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

  test('a pack with no source asks for a link, then remembers it', () async {
    final server = FakeServer();
    final pack = await installRemotePack(
        await fetchRemotePack('a/maps/silksong', client: server.client),
        client: server.client, root: root);
    File(p.join(pack.dir, '.source.json')).deleteSync(); // as if sideloaded

    await expectLater(checkForUpdate(pack, client: server.client), throwsA(isA<PackNeedsLink>()));
    expect(await checkForUpdate(pack, link: 'a/maps/silksong', client: server.client), isNull);
    expect(await installedFrom(pack), 'a/maps/silksong');
    expect(await checkForUpdate(pack, client: server.client), isNull, reason: 'remembered');
  });

  test('guesses a link from release URLs named by publish_pack', () {
    final m = PackManifest.fromJson(jsonDecode(manifest()) as Map<String, dynamic>);
    expect(guessPackLink(m), 'a/maps', reason: 'tag "v1" has no folder prefix');
    final named = PackManifest.fromJson({
      ...jsonDecode(manifest()) as Map<String, dynamic>,
      'maps': [
        {
          'id': 'w',
          'name': 'W',
          'image': {'width': 1, 'height': 1},
          'maxZoom': 0,
          'tiles': {
            'archive': 'https://github.com/rahulskann/demo_maps/releases/download/silksong-v0.8.0/w.zip',
            'path': '{z}/{x}/{y}.png',
          },
        },
      ],
    });
    expect(guessPackLink(named), 'rahulskann/demo_maps/silksong');
    final local = PackManifest.fromJson({
      ...jsonDecode(manifest()) as Map<String, dynamic>,
      'maps': [
        {'id': 'w', 'name': 'W', 'image': {'width': 1, 'height': 1},
         'maxZoom': 0, 'tiles': {'archive': 'out/w.zip', 'path': '{z}/{x}/{y}.png'}},
      ],
    });
    expect(guessPackLink(local), isNull);
  });
}
