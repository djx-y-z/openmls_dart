import 'package:test/test.dart';

import '../../scripts/src/release_frb.dart';

void main() {
  group('stampFrbHighlight', () {
    test('replaces an existing openmls_frb highlight in place', () {
      const changelog = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls v0.97.3** — internal/dependency update, no public-API impact
- **openmls_frb v5.1.0** — Rust FFI bindings

#### Changed

- Update openmls native library to v0.97.3

## [6.0.0] - 2026-07-14
''';
      final result = stampFrbHighlight(changelog, '5.2.0');
      expect(result, contains('**openmls_frb v5.2.0** — Rust FFI bindings'));
      expect(result, isNot(contains('openmls_frb v5.1.0')));
      // The openmls highlight is untouched.
      expect(result, contains('**openmls v0.97.3**'));
    });

    test('replaces a wrapped frb highlight whole', () {
      // Regression: the replace branch overwrote only the bullet's first line.
      // A hand-edited highlight that wraps left its continuation behind, and
      // that orphan then rode into the released section this stamp closes —
      // which the changelog contract forbids editing afterwards.
      const changelog = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls_frb v5.1.0** — Rust FFI bindings, and a sentence somebody
  wrapped onto a second, indented line while explaining the change.

#### Changed

- Update openmls native library to v0.97.3

## [6.0.0] - 2026-07-14
''';
      final result = stampFrbHighlight(changelog, '5.2.0');
      expect(result, contains('v5.2.0** — Rust FFI bindings'));
      expect(result, isNot(contains('wrapped onto a second')));
      expect(result, isNot(contains('v5.1.0')));
      // The rest of the section survives intact.
      expect(result, contains('#### Changed'));
      expect(result, contains('- Update'));
    });

    test('replaces a lazily wrapped frb highlight', () {
      // A continuation line need not be indented: with no blank line between
      // them it is still the same bullet.
      const changelog = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls_frb v5.1.0** — Rust FFI bindings
still the same bullet, just not indented

## [6.0.0] - 2026-07-14
''';
      final result = stampFrbHighlight(changelog, '5.2.0');
      expect(result, isNot(contains('still the same bullet')));
      expect(result, contains('v5.2.0** — Rust FFI bindings'));
    });

    test('leaves the paragraph after the highlight alone', () {
      // The other half of the rule: a blank line ends the bullet unless what
      // follows is indented, so an ordinary paragraph is not swallowed.
      const changelog = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls_frb v5.1.0** — Rust FFI bindings

A paragraph that belongs to the section, not to the bullet.

## [6.0.0] - 2026-07-14
''';
      final result = stampFrbHighlight(changelog, '5.2.0');
      expect(result, contains('A paragraph that belongs to the section'));
      expect(result, contains('v5.2.0** — Rust FFI bindings'));
    });

    test('inserts after a wrapped highlight, not inside it', () {
      // Regression: the insert used to land between the first and second line
      // of a highlight that wrapped, splitting the sentence in half. A bullet's
      // continuation lines are indented and do not start with `- `, so the
      // insert point has to be the end of the block, not `lastBullet + 1`.
      const changelog = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls v0.97.5** — upstream bump. One change does land in a surface this
  package exposes, and it is an internal API migration with no behavioural
  effect

#### Changed

- Update openmls native library to v0.97.5

## [6.0.0] - 2026-07-14
''';
      final result = stampFrbHighlight(changelog, '5.2.0');
      final lines = result.split('\n');

      final frbIdx = lines.indexWhere(
        (l) => l.contains('**openmls_frb v5.2.0**'),
      );
      final lastContinuationIdx = lines.indexWhere((l) => l.contains('effect'));
      expect(frbIdx, greaterThan(lastContinuationIdx));

      // The wrapped bullet survives as one contiguous block.
      expect(
        result,
        contains(
          '- **openmls v0.97.5** — upstream bump. One change does land in a surface this\n'
          '  package exposes, and it is an internal API migration with no behavioural\n'
          '  effect\n',
        ),
      );
    });

    test('replaces the frb line in place when the highlight above it wraps', () {
      // The re-run case after a failed native build: the frb line is already
      // there, below a wrapped highlight, and only its version moves.
      const changelog = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls v0.97.5** — upstream bump. One change does land in a surface this
  package exposes, and it is an internal API migration with no behavioural
  effect
- **openmls_frb v5.1.0** — Rust FFI bindings

#### Changed

- Update openmls native library to v0.97.5

## [6.0.0] - 2026-07-14
''';
      final result = stampFrbHighlight(changelog, '5.2.0');
      expect(result, contains('**openmls_frb v5.2.0** — Rust FFI bindings'));
      expect(result, isNot(contains('openmls_frb v5.1.0')));
      expect(
        result,
        contains(
          '- **openmls v0.97.5** — upstream bump. One change does land in a surface this\n'
          '  package exposes, and it is an internal API migration with no behavioural\n'
          '  effect\n'
          '- **openmls_frb v5.2.0** — Rust FFI bindings\n',
        ),
      );
    });

    test('inserts after the last highlight when no frb line exists', () {
      const changelog = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls v0.97.4** — internal/dependency update, no public-API impact

#### Changed

- Update openmls native library to v0.97.4

## [6.0.0] - 2026-07-14
''';
      final result = stampFrbHighlight(changelog, '5.2.0');
      final lines = result.split('\n');
      final nativeIdx = lines.indexWhere(
        (l) => l.contains('**openmls v0.97.4**'),
      );
      final frbIdx = lines.indexWhere(
        (l) => l.contains('**openmls_frb v5.2.0**'),
      );
      expect(nativeIdx, greaterThanOrEqualTo(0));
      expect(
        frbIdx,
        equals(nativeIdx + 1),
        reason: 'frb line should follow the openmls highlight',
      );
      // Did not leak into the released section.
      final releasedIdx = lines.indexWhere((l) => l.startsWith('## [6.0.0]'));
      expect(frbIdx, lessThan(releasedIdx));
    });

    test('creates an [Unreleased] section when none exists', () {
      const changelog = '''
# Changelog

## [6.0.0] - 2026-07-14

### For Users

- something
''';
      final result = stampFrbHighlight(changelog, '5.2.0');
      expect(result, contains('## [Unreleased]'));
      expect(result, contains('#### ✨ Highlights'));
      expect(result, contains('**openmls_frb v5.2.0** — Rust FFI bindings'));
      // Unreleased must come before the first released version.
      final lines = result.split('\n');
      expect(
        lines.indexWhere((l) => l.startsWith('## [Unreleased]')),
        lessThan(lines.indexWhere((l) => l.startsWith('## [6.0.0]'))),
      );
    });

    test('is idempotent across repeated runs (replace, not duplicate)', () {
      const changelog = '''
## [Unreleased]

### For Users

#### ✨ Highlights

- **openmls v0.97.4** — internal/dependency update, no public-API impact

## [6.0.0] - 2026-07-14
''';
      final once = stampFrbHighlight(changelog, '5.2.0');
      final twice = stampFrbHighlight(once, '5.2.0');
      final count = '**openmls_frb v5.2.0**'.allMatches(twice).length;
      expect(count, equals(1), reason: 'must not accumulate duplicate lines');
    });

    test('creates the ### For Users parent when stamping into an empty '
        '[Unreleased] (no orphan Highlights block)', () {
      // A bare [Unreleased] heading with no audience sections (e.g. added by
      // hand): heading + blank only.
      const changelog = '''
## [Unreleased]

## [6.0.0] - 2026-07-14

### For Users

- something
''';
      final result = stampFrbHighlight(changelog, '5.3.0');
      final lines = result.split('\n');
      final unreleasedIdx = lines.indexWhere(
        (l) => l.startsWith('## [Unreleased]'),
      );
      final forUsersIdx = lines.indexWhere(
        (l) => l.startsWith('### For Users'),
      );
      final highlightsIdx = lines.indexWhere(
        (l) => l.startsWith('#### ✨ Highlights'),
      );
      final releasedIdx = lines.indexWhere((l) => l.startsWith('## [6.0.0]'));
      // The stamped Highlights block sits under a For Users heading that is
      // itself inside the [Unreleased] section (before the released heading).
      expect(unreleasedIdx, lessThan(forUsersIdx));
      expect(forUsersIdx, lessThan(highlightsIdx));
      expect(highlightsIdx, lessThan(releasedIdx));
      expect(result, contains('**openmls_frb v5.3.0** — Rust FFI bindings'));
    });
  });

  group('bumpCargoLockVersion', () {
    const lock = '''
# This file is automatically @generated by Cargo.

[[package]]
name = "openmls_frb"
version = "5.1.0"
dependencies = [
 "flutter_rust_bridge",
]

[[package]]
name = "other_crate"
version = "5.1.0"
''';

    test('bumps only the named crate stanza, not a coincidental match', () {
      final result = bumpCargoLockVersion(lock, 'openmls_frb', '5.2.0');
      expect(result, contains('name = "openmls_frb"\nversion = "5.2.0"'));
      // A different package that happens to share the old version is untouched.
      expect(result, contains('name = "other_crate"\nversion = "5.1.0"'));
    });

    test('throws when the crate stanza is absent', () {
      expect(
        () => bumpCargoLockVersion(lock, 'missing_crate', '5.2.0'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
