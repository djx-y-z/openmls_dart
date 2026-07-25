import 'package:test/test.dart';

import '../../scripts/src/check_updates.dart';
import '../../scripts/src/common.dart';

void main() {
  group('validateUpstreamTag', () {
    test('accepts the exact upstream tag form', () {
      expect(validateUpstreamTag('openmls-v0.8.1'), 'openmls-v0.8.1');
      expect(validateUpstreamTag('openmls-v1.0.0'), 'openmls-v1.0.0');
      expect(validateUpstreamTag('openmls-v10.20.30'), 'openmls-v10.20.30');
    });

    test('accepts semver prerelease identifiers', () {
      expect(
        validateUpstreamTag('openmls-v0.9.0-pre.1'),
        'openmls-v0.9.0-pre.1',
      );
      expect(validateUpstreamTag('openmls-v1.0.0-rc-2'), 'openmls-v1.0.0-rc-2');
    });

    // Regression guard: the previous pattern was `^v?\d+\.\d+\.\d+$`, which
    // silently rejected this repo's own `openmls-v` prefix and broke the
    // scheduled update check. The pattern must be derived from the configured
    // tag prefix, never hardcoded to a bare `v`.
    test('accepts the tag recorded in rust/Cargo.toml', () {
      expect(() => validateUpstreamTag(getUpstreamVersion()), returnsNormally);
    });

    test('rejects a bare version without the configured prefix', () {
      expect(() => validateUpstreamTag('v0.8.1'), throwsFormatException);
      expect(() => validateUpstreamTag('0.8.1'), throwsFormatException);
    });

    test('rejects shell metacharacters', () {
      for (final tag in const [
        'openmls-v0.8.1; rm -rf /',
        r'openmls-v0.8.1$(whoami)',
        'openmls-v0.8.1`id`',
        'openmls-v0.8.1 --force',
        'openmls-v0.8.1 && echo pwned',
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
        () => validateUpstreamTag('openmls-v0.8.1\nmalicious'),
        throwsFormatException,
      );
      expect(
        () => validateUpstreamTag('openmls-v0.8.1\n'),
        throwsFormatException,
      );
    });

    test('rejects path traversal', () {
      expect(
        () => validateUpstreamTag('openmls-v../../etc/passwd'),
        throwsFormatException,
      );
      expect(
        () => validateUpstreamTag('openmls-v0.8.1/../evil'),
        throwsFormatException,
      );
    });

    test('rejects a prefix that is not at the start', () {
      expect(
        () => validateUpstreamTag('xopenmls-v0.8.1'),
        throwsFormatException,
      );
    });

    test('rejects non-canonical numeric segments', () {
      expect(
        () => validateUpstreamTag('openmls-v0.08.1'),
        throwsFormatException,
      );
      expect(() => validateUpstreamTag('openmls-v0.8'), throwsFormatException);
      expect(
        () => validateUpstreamTag('openmls-v0.8.1.2'),
        throwsFormatException,
      );
    });
  });
}
