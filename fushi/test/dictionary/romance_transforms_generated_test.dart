// pt.json / it.json (tool/gen_romance_transforms.dart) and de_extended.json /
// la_extended.json / el_extended.json / ru.json
// (tool/gen_extended_transforms.dart) are generated. A hand edit to one would
// be lost on the next run of its generator, and a generator change that was
// never run would ship stale rules, so the checked-in files must match the
// output byte for byte.
//
// The lookup behaviour itself is covered by the native
// romance_inflection_lookup_test and european_inflection_lookup_test.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/gen_extended_transforms.dart' as ext;
import '../../tool/gen_romance_transforms.dart' as gen;

void main() {
  const String dir = 'assets/transforms';

  for (final gen.TransformTable table in <gen.TransformTable>[
    gen.portuguese(),
    gen.italian(),
    ext.german(),
    ext.latin(),
    ext.greek(),
    ext.russian(),
  ]) {
    test('${table.fileName}.json matches the generator', () {
      final File file = File('$dir/${table.fileName}.json');
      expect(file.existsSync(), isTrue, reason: 'missing ${file.path}');
      expect(
        file.readAsStringSync(),
        '${table.encode()}\n',
        reason:
            'Regenerate with `dart run tool/gen_romance_transforms.dart` / '
            '`tool/gen_extended_transforms.dart` (from fushi/) instead of '
            'editing the JSON by hand.',
      );
    });
  }

  test('manifest lists every generated table, extensions after their base', () {
    final List<dynamic> manifest =
        jsonDecode(File('$dir/manifest.json').readAsStringSync())
            as List<dynamic>;
    expect(manifest, containsAll(<String>['pt', 'it', 'ru']));
    for (final String base in <String>['de', 'la', 'el']) {
      // The engine allocates an extension's new conditions after the base
      // file's, so the base must be loaded first.
      expect(
        manifest.indexOf('${base}_extended'),
        manifest.indexOf(base) + 1,
        reason: '${base}_extended must follow $base',
      );
    }
  });
}
