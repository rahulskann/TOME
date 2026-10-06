import 'package:flutter_test/flutter_test.dart';
import 'package:tome/pack/pack_location.dart';

List<String> c(String input) => [for (final u in packFolderCandidates(input)) u.toString()];

void main() {
  const raw = 'https://raw.githubusercontent.com';

  test('GitHub shorthand, with and without a folder', () {
    expect(c('rahulskann/demo_maps'),
        ['$raw/rahulskann/demo_maps/main/', '$raw/rahulskann/demo_maps/master/']);
    expect(c('rahulskann/demo_maps/silksong'), [
      '$raw/rahulskann/demo_maps/main/silksong/',
      '$raw/rahulskann/demo_maps/master/silksong/',
    ]);
  });

  test('github.com links, with or without scheme and .git', () {
    expect(c('https://github.com/rahulskann/demo_maps.git').first,
        '$raw/rahulskann/demo_maps/main/');
    expect(c('github.com/rahulskann/demo_maps/silksong').first,
        '$raw/rahulskann/demo_maps/main/silksong/');
  });

  test('tree and blob links pin the branch', () {
    expect(c('https://github.com/a/b/tree/dev/packs/x'), ['$raw/a/b/dev/packs/x/']);
    expect(c('https://github.com/a/b/blob/v2/packs/x/pack.json'), ['$raw/a/b/v2/packs/x/']);
  });

  test('raw and other hosts', () {
    expect(c('$raw/a/b/main/x/pack.json'), ['$raw/a/b/main/x/']);
    expect(c('https://example.com/maps/x/pack.json'), ['https://example.com/maps/x/']);
    expect(c('https://example.com/maps/x'), ['https://example.com/maps/x/']);
  });

  test('rejects junk', () {
    expect(c(''), isEmpty);
    expect(c('hello'), isEmpty);
    expect(c('ftp://x/y'), isEmpty);
    expect(c('https://github.com/onlyowner'), isEmpty);
  });

  test('resolves archive and markers paths', () {
    final folder = Uri.parse('$raw/a/b/main/x/');
    expect(resolveInPack(folder, 'out/world-tiles.zip').toString(), '$raw/a/b/main/x/out/world-tiles.zip');
    expect(resolveInPack(folder, 'https://github.com/a/b/releases/download/t/w.zip').toString(),
        'https://github.com/a/b/releases/download/t/w.zip');
  });
}
