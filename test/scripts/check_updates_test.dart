import 'package:test/test.dart';

import '../../scripts/src/check_updates.dart';
import '../../scripts/src/common.dart';

/// The configured upstream tag prefix ('openmls-v').
///
/// Tests build their fixtures from this rather than hardcoding a prefix, so a
/// project generated with a non-default prefix still exercises its own format.
const _prefix = 'openmls-v';

void main() {
  group('validateUpstreamTag', () {
    test('accepts the exact upstream tag form', () {
      expect(validateUpstreamTag('${_prefix}0.8.1'), '${_prefix}0.8.1');
      expect(validateUpstreamTag('${_prefix}1.0.0'), '${_prefix}1.0.0');
      expect(validateUpstreamTag('${_prefix}10.20.30'), '${_prefix}10.20.30');
    });

    test('accepts semver prerelease identifiers', () {
      expect(
        validateUpstreamTag('${_prefix}0.9.0-pre.1'),
        '${_prefix}0.9.0-pre.1',
      );
      // Kept wrapped: on one line this renders to 82 columns and `dart format`
      // rewrites it, so every generated project would ship a file its own
      // `make format-check` rejects. Nothing on this line is interpolated by
      // Jinja, so the width is identical for every project.
      expect(
        validateUpstreamTag('${_prefix}1.0.0-rc-2'),
        '${_prefix}1.0.0-rc-2',
      );
    });

    // Regression guard: an earlier version of this template hardcoded
    // `^v?\d+\.\d+\.\d+$` here, which silently rejected every tag of a project
    // whose upstream uses a non-default prefix. The scheduled update check then
    // failed on every run, hidden behind a `|| true` in the workflow. The
    // pattern must be derived from the configured prefix, never hardcoded.
    test('accepts the tag recorded in rust/Cargo.toml', () {
      expect(() => validateUpstreamTag(getUpstreamVersion()), returnsNormally);
    });

    test('rejects a bare version without the configured prefix', () {
      expect(() => validateUpstreamTag('0.8.1'), throwsFormatException);
      // `v` is the default prefix, so a tag in that shape is the likeliest
      // thing to reach a project that overrides it — from a copied command
      // line, or from a sibling repo. It names a different upstream naming
      // scheme and must be rejected just like a bare version.
      expect(() => validateUpstreamTag('v0.8.1'), throwsFormatException);
    });

    test('rejects shell metacharacters', () {
      for (final tag in <String>[
        '${_prefix}0.8.1; rm -rf /',
        '${_prefix}0.8.1\$(whoami)',
        '${_prefix}0.8.1`id`',
        '${_prefix}0.8.1 --force',
        '${_prefix}0.8.1 && echo pwned',
      ]) {
        expect(
          () => validateUpstreamTag(tag),
          throwsFormatException,
          reason: 'must reject: $tag',
        );
      }
    });

    test('rejects newline injection, including a bare trailing newline', () {
      expect(
        () => validateUpstreamTag('${_prefix}0.8.1\nmalicious'),
        throwsFormatException,
      );
      expect(
        () => validateUpstreamTag('${_prefix}0.8.1\n'),
        throwsFormatException,
      );
    });

    test('rejects path traversal', () {
      expect(
        // No braces: the next character is not identifier-continuation, so
        // `unnecessary_brace_in_string_interps` fires under --fatal-infos.
        () => validateUpstreamTag('$_prefix../../etc/passwd'),
        throwsFormatException,
      );
      expect(
        () => validateUpstreamTag('${_prefix}0.8.1/../evil'),
        throwsFormatException,
      );
    });

    test('rejects a prefix that is not at the start', () {
      expect(
        () => validateUpstreamTag('x${_prefix}0.8.1'),
        throwsFormatException,
      );
    });

    test('rejects non-canonical numeric segments', () {
      expect(
        () => validateUpstreamTag('${_prefix}0.08.1'),
        throwsFormatException,
      );
      expect(() => validateUpstreamTag('${_prefix}0.8'), throwsFormatException);
      expect(
        () => validateUpstreamTag('${_prefix}0.8.1.2'),
        throwsFormatException,
      );
    });

    test('names the rejected source in the message', () {
      // The call sites (API response, --version argument, recorded pin) fail
      // for different reasons; the message has to say which one to look at.
      expect(
        () => validateUpstreamTag('nope', source: '--version argument'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--version argument'),
          ),
        ),
      );
    });
  });
}
