import 'dart:convert';

import 'package:test/test.dart';

import '../../scripts/src/example_library.dart';

void main() {
  const local = '/repo/rust/target/x86_64-linux-android/release/lib.so';
  const downloaded =
      '/repo/example/.dart_tool/hooks_runner/shared/mypackage/build/8.0.0-android-x86_64/lib.so';

  group('libraryCameFrom', () {
    test('tells a local build from a download', () {
      expect(libraryCameFrom(local, LibrarySource.built), isTrue);
      expect(libraryCameFrom(local, LibrarySource.released), isFalse);
      expect(libraryCameFrom(downloaded, LibrarySource.built), isFalse);
      expect(libraryCameFrom(downloaded, LibrarySource.released), isTrue);
    });

    test('reads a Windows path', () {
      expect(
        libraryCameFrom(
          r'D:\a\repo\rust\target\release\lib.dll',
          LibrarySource.built,
        ),
        isTrue,
      );
    });
  });

  group('librariesInHookOutput', () {
    test('takes the file of each registered asset', () {
      expect(
        librariesInHookOutput(
          jsonEncode({
            'assets': [
              {
                'encoding': {
                  'file': local,
                  'id': 'package:mypackage/mypackage',
                },
                'type': 'code_assets/code',
              },
            ],
            'dependencies': ['/repo/rust/Cargo.toml'],
          }),
        ),
        [local],
      );
    });

    test('a hook that registered nothing has no libraries', () {
      expect(librariesInHookOutput('{"assets": []}'), isEmpty);
      expect(librariesInHookOutput('{}'), isEmpty);
    });
  });

  group('libraryProblems', () {
    test('the right source is no problem', () {
      expect(libraryProblems([local], LibrarySource.built), isEmpty);
      expect(libraryProblems([downloaded], LibrarySource.released), isEmpty);
    });

    test('a run on the wrong library says which', () {
      expect(
        libraryProblems([downloaded], LibrarySource.built).single,
        contains(downloaded),
      );
    });

    test('no library at all is a problem, not a pass', () {
      expect(libraryProblems([], LibrarySource.built), isNotEmpty);
      expect(libraryProblems([], LibrarySource.released), isNotEmpty);
    });
  });

  group('webModuleProblems', () {
    test('a local module is built, a version is released', () {
      expect(webModuleProblems('local-dev\n', LibrarySource.built), isEmpty);
      expect(webModuleProblems('8.0.0\n', LibrarySource.released), isEmpty);
    });

    test('the other way round is a problem', () {
      expect(webModuleProblems('8.0.0\n', LibrarySource.built), isNotEmpty);
      expect(
        webModuleProblems('local-dev\n', LibrarySource.released),
        isNotEmpty,
      );
    });

    test('no marker is a problem whichever is wanted', () {
      expect(webModuleProblems(null, LibrarySource.built), isNotEmpty);
      expect(webModuleProblems(null, LibrarySource.released), isNotEmpty);
    });
  });
}
