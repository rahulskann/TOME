import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'pack.dart';
import 'pack_location.dart';
import 'pack_store.dart';

/// A pack's manifest fetched from the web, not yet installed.
class RemotePack {
  const RemotePack({
    required this.input,
    required this.folder,
    required this.manifest,
    required this.manifestJson,
  });

  /// What the user entered; kept so updates can be fetched the same way.
  final String input;

  /// URL of the folder holding `pack.json`, ending in `/`.
  final Uri folder;
  final PackManifest manifest;
  final String manifestJson;

  /// Sum of the maps' declared archive sizes, or null if any is unknown.
  int? get downloadBytes {
    var total = 0;
    for (final m in manifest.maps) {
      final size = m.archiveBytes;
      if (size == null) return null;
      total += size;
    }
    return total;
  }
}

class PackFetchException implements Exception {
  const PackFetchException(this.message);
  final String message;
  @override
  String toString() => message;
}

class InstallCancelled implements Exception {
  const InstallCancelled();
}

/// Set [cancelled] to stop an install; its partial downloads are kept so the
/// next attempt resumes.
class CancelToken {
  bool cancelled = false;
}

class InstallProgress {
  const InstallProgress(this.message, [this.fraction]);

  final String message;

  /// 0..1, or null when unknown.
  final double? fraction;
}

// Files the app writes inside an installed pack, next to pack.json.
const sourceFileName = '.source.json'; // where it was installed from
const bundledFileName = '.bundled'; // shipped inside the app
const installedSnapshotDir = '.installed'; // markers as downloaded
const sideloadedSnapshotDir = '.sideloaded'; // markers as sideloaded (tools/)

/// Finds and parses `pack.json` for what the user typed.
Future<RemotePack> fetchRemotePack(String input, {http.Client? client}) async {
  final candidates = packFolderCandidates(input);
  if (candidates.isEmpty) {
    throw const PackFetchException(
        'That doesn\'t look like a link. Try owner/repo, owner/repo/folder or a github.com link.');
  }
  final c = client ?? http.Client();
  try {
    for (final folder in candidates) {
      final http.Response resp;
      try {
        resp = await c.get(folder.resolve('pack.json'));
      } on SocketException {
        throw const PackFetchException('Couldn\'t reach the internet. Check your connection.');
      } on http.ClientException catch (e) {
        throw PackFetchException('Couldn\'t download pack.json: ${e.message}');
      }
      if (resp.statusCode == 404) continue;
      if (resp.statusCode != 200) {
        throw PackFetchException('Couldn\'t download pack.json (HTTP ${resp.statusCode}).');
      }
      final text = utf8.decode(resp.bodyBytes);
      try {
        final manifest = PackManifest.fromJson(jsonDecode(text) as Map<String, dynamic>);
        return RemotePack(input: input.trim(), folder: folder, manifest: manifest, manifestJson: text);
      } on FormatException catch (e) {
        throw PackFetchException(e.message);
      } catch (e) {
        throw PackFetchException('pack.json isn\'t a valid TOME pack: $e');
      }
    }
    throw PackFetchException('No pack.json found at ${candidates.first}');
  } finally {
    if (client == null) c.close();
  }
}

/// Downloads and installs [remote], replacing any installed version only once
/// everything is in place.
Future<InstalledPack> installRemotePack(
  RemotePack remote, {
  http.Client? client,
  Directory? root,
  void Function(InstallProgress)? onProgress,
  CancelToken? cancel,
}) async {
  final c = client ?? http.Client();
  final packs = root ?? await packsRoot();
  final id = remote.manifest.id;
  final staging = Directory(p.join(packs.path, '.staging-$id'));
  final downloads = Directory(p.join(packs.path, '.downloads', id));
  final total = remote.downloadBytes;
  var doneBytes = 0;
  void report(String message, [int extra = 0]) => onProgress?.call(InstallProgress(
      message, total == null || total == 0 ? null : ((doneBytes + extra) / total).clamp(0, 1)));

  try {
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    await downloads.create(recursive: true);

    final maps = remote.manifest.maps;
    for (var i = 0; i < maps.length; i++) {
      final map = maps[i];
      final label = maps.length > 1 ? '${map.name} (${i + 1}/${maps.length})' : map.name;
      final part = File(p.join(downloads.path,
          '${map.id}-${remote.manifest.version}.zip.part'.replaceAll(RegExp(r'[^\w.-]'), '_')));
      await _download(c, resolveInPack(remote.folder, map.tilesArchive), part,
          cancel: cancel, onBytes: (n) => report('Downloading $label', n));
      doneBytes += map.archiveBytes ?? await part.length();

      report('Unpacking $label');
      final input = InputFileStream(part.path);
      try {
        await extractArchiveToDisk(
            ZipDecoder().decodeStream(input), p.join(staging.path, map.id, 'tiles'));
      } catch (e) {
        await part.delete(); // likely corrupt; don't resume from it
        throw PackFetchException('The tiles for ${map.name} couldn\'t be unpacked: $e');
      } finally {
        await input.close();
      }
      _checkCancel(cancel);

      final markersPath = map.markersPath;
      if (markersPath != null) {
        report('Downloading markers for $label');
        final resp = await c.get(resolveInPack(remote.folder, markersPath));
        if (resp.statusCode != 200) {
          throw PackFetchException('Couldn\'t download $markersPath (HTTP ${resp.statusCode}).');
        }
        MapMarker.listFromJson(jsonDecode(utf8.decode(resp.bodyBytes)) as List); // validate
        for (final dir in [staging.path, p.join(staging.path, installedSnapshotDir)]) {
          final out = File(p.join(dir, markersPath));
          await out.parent.create(recursive: true);
          await out.writeAsBytes(resp.bodyBytes);
        }
      }
    }

    await File(p.join(staging.path, sourceFileName)).writeAsString(jsonEncode({
      'input': remote.input,
      'folder': remote.folder.toString(),
      'installedAt': DateTime.now().toUtc().toIso8601String(),
    }));
    // Last: a folder without pack.json is never listed as installed.
    await File(p.join(staging.path, 'pack.json')).writeAsString(remote.manifestJson);

    report('Finishing');
    final target = Directory(p.join(packs.path, id));
    final old = Directory(p.join(packs.path, '.old-$id'));
    if (await old.exists()) await old.delete(recursive: true);
    if (await target.exists()) await target.rename(old.path);
    await staging.rename(target.path);
    if (await old.exists()) await old.delete(recursive: true);
    await downloads.delete(recursive: true);
    return await openInstalledPack(target.path);
  } finally {
    if (client == null) c.close();
    // Partial downloads stay for resuming; a half-built staging folder doesn't.
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

/// Streams [url] into [part], resuming from what's already there.
Future<void> _download(
  http.Client client,
  Uri url,
  File part, {
  CancelToken? cancel,
  required void Function(int received) onBytes,
}) async {
  var have = await part.exists() ? await part.length() : 0;
  final request = http.Request('GET', url);
  if (have > 0) request.headers['range'] = 'bytes=$have-';
  final http.StreamedResponse resp;
  try {
    resp = await client.send(request);
  } on SocketException {
    throw const PackFetchException('Lost the connection. Try again to resume the download.');
  }
  if (resp.statusCode == 416 && have > 0) {
    // Already complete (the server has nothing past what we hold).
    await resp.stream.drain<void>();
    onBytes(have);
    return;
  }
  if (resp.statusCode != 200 && resp.statusCode != 206) {
    await resp.stream.drain<void>();
    throw PackFetchException('Download failed (HTTP ${resp.statusCode}) for $url');
  }
  if (resp.statusCode == 200) have = 0; // server ignored the range: start over
  final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
  var received = have;
  try {
    await for (final chunk in resp.stream) {
      if (cancel?.cancelled ?? false) throw const InstallCancelled();
      sink.add(chunk);
      received += chunk.length;
      onBytes(received);
    }
  } on SocketException {
    throw const PackFetchException('Lost the connection. Try again to resume the download.');
  } on http.ClientException {
    throw const PackFetchException('Lost the connection. Try again to resume the download.');
  } finally {
    await sink.close();
  }
}

void _checkCancel(CancelToken? cancel) {
  if (cancel?.cancelled ?? false) throw const InstallCancelled();
}

/// Where an installed pack came from, if it was downloaded.
Future<String?> installedFrom(InstalledPack pack) async {
  final file = File(p.join(pack.dir, sourceFileName));
  if (!await file.exists()) return null;
  try {
    return (jsonDecode(await file.readAsString()) as Map<String, dynamic>)['input'] as String?;
  } on FormatException {
    return null;
  }
}

bool isBundled(InstalledPack pack) => File(p.join(pack.dir, bundledFileName)).existsSync();

/// The newer version of [pack] if its source has one, else null.
Future<RemotePack?> checkForUpdate(InstalledPack pack, {http.Client? client}) async {
  final input = await installedFrom(pack);
  if (input == null) {
    throw const PackFetchException('This pack wasn\'t downloaded from a link, so it can\'t be updated here.');
  }
  final remote = await fetchRemotePack(input, client: client);
  if (remote.manifest.id != pack.manifest.id) {
    throw PackFetchException('The link now holds a different pack (${remote.manifest.id}).');
  }
  return remote.manifest.version == pack.manifest.version ? null : remote;
}

/// True if markers were changed on this device since the pack was installed,
/// so an update would replace them.
Future<bool> hasLocalMarkerEdits(InstalledPack pack) async {
  for (final map in pack.manifest.maps) {
    final current = File(p.join(pack.dir, map.markersFile));
    if (!await current.exists()) continue;
    File? snapshot;
    for (final dir in [installedSnapshotDir, sideloadedSnapshotDir]) {
      final f = File(p.join(pack.dir, dir, map.markersFile));
      if (await f.exists()) snapshot = f;
    }
    if (snapshot == null) continue; // nothing to compare against
    final a = jsonDecode(await current.readAsString());
    final b = jsonDecode(await snapshot.readAsString());
    if (jsonEncode(a) != jsonEncode(b)) return true;
  }
  return false;
}

/// Removes [pack] from the device. Progress is kept, so reinstalling restores it.
Future<void> deletePack(InstalledPack pack) => Directory(pack.dir).delete(recursive: true);
