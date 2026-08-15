import 'dart:io';

import 'package:openmls/src/platform/platform_io.dart';
import 'package:test/test.dart';

/// The literal directory name flutter_tools installs code assets under, spelled
/// out per host rather than derived from `Platform.operatingSystem` — that is
/// the implementation's own expression, and reusing it would make the test pass
/// even if the token were wrong.
String hostAssetDir() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  throw UnsupportedError('unexpected test host: ${Platform.operatingSystem}');
}

void main() {
  group('nativeAssetSearchPaths', () {
    test('probes the directory `flutter test` installs the library into', () {
      expect(
        nativeAssetSearchPaths('libopenmls_frb.so'),
        contains('build/native_assets/${hostAssetDir()}/libopenmls_frb.so'),
        reason:
            '`flutter test` installs the registered CodeAsset under '
            'build/native_assets/<os>/ and never creates .dart_tool/lib/. '
            'The asset id is not a path so it cannot be dlopen()ed, and on '
            "macOS and Linux nothing on flutter_tester's search path covers "
            'that directory - so dropping this entry makes init() fail in the '
            'unit tests of every Flutter package that depends on us.',
      );
    });

    test('probes the bundled locations before the working-directory one', () {
      final paths = nativeAssetSearchPaths('libx.so');

      expect(
        paths.first,
        '.dart_tool/lib/libx.so',
        reason:
            '`dart run`/`dart test` is the hot path and the only location the '
            'SDK itself provisions.',
      );
      expect(
        paths.where((p) => p.endsWith('/../lib/libx.so')),
        isNotEmpty,
        reason:
            'AOT bundles (`dart build cli`) put the library in lib/ next to '
            'the executable.',
      );
      expect(
        paths.last,
        'build/native_assets/${hostAssetDir()}/libx.so',
        reason:
            'This entry is relative to the working directory, so it must stay '
            'behind the AOT bundle: a compiled application launched from an '
            'arbitrary directory has to load the library it shipped with, not '
            'one that happens to sit in that directory.',
      );
    });
  });
}
