import 'package:test/test.dart';

import '../../scripts/src/check_updates.dart';
import '../../scripts/src/upstream_source.dart';

// What a pin looks like, and how one is read, validated and written, belongs
// to the upstream source and is tested with it, in upstream_source_test.dart.
// What is left here is what this file does with a version once it has one.

void main() {
  group('updateReadmeBadge', () {
    // Held in a Dart const rather than interpolated at every use, so the lines
    // below have the same width in every generated project and `dart format`
    // has nothing to rewrite whatever the library is called.
    const lib = 'openmls';
    String badge(String version) =>
        '[![$lib](https://img.shields.io/badge/$lib-$version-orange.svg)]';

    test('writes the version', () {
      expect(updateReadmeBadge(badge('v0.8.1'), '0.9.0'), badge('v0.9.0'));
    });

    test('keeps a badge that omits the leading v', () {
      expect(updateReadmeBadge(badge('0.8.1'), '0.9.0'), badge('0.9.0'));
    });

    test('leaves content with no badge alone', () {
      const readme = 'no badge here';
      expect(updateReadmeBadge(readme, '0.9.0'), readme);
    });

    // Regression: the badge was written from the raw tag, which every other
    // file a bump rewrites genuinely needs. With a prefix other than a bare
    // `v` it spelled the prefix twice — `badge/<lib>-<prefix>0.9.0` — because
    // the badge text already carries the library name. What is written is the
    // source's `semverOf` of the pin, whichever source it is.
    test('never writes a tag prefix into the badge text', () {
      const source = GitTagSource(
        repo: 'owner/upstream',
        crates: ['upstream-core'],
        tagPrefix: 'upstream-v',
      );
      expect(
        updateReadmeBadge(badge('v0.8.1'), source.semverOf('upstream-v0.9.0')),
        badge('v0.9.0'),
      );
    });
  });
}
