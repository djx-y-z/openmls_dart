import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/src/pub_limits.dart';

void main() {
  // The numbers pub-dev's pkg/pub_package_reader enforces. A change here is a
  // change of what this gate claims to protect against, not a tuning knob.
  test("the limits are pub.dev's", () {
    expect(pubContentLimit, 262144);
    expect(pubspecLimit, 131072);
    expect(pubContentWarnAt, lessThan(pubContentLimit));
  });

  group('pubContentFiles', () {
    test('lists the page files, then the example candidates in order', () {
      expect(pubContentFiles('pkg'), [
        'README.md',
        'CHANGELOG.md',
        'LICENSE',
        'example/example.md',
        'example/lib/main.dart',
        'example/main.dart',
        'example/lib/pkg.dart',
        'example/pkg.dart',
        'example/lib/pkg_example.dart',
        'example/pkg_example.dart',
        'example/lib/example.dart',
        'example/example.dart',
        'example/README.md',
      ]);
    });
  });

  group('packageNameFromPubspec', () {
    test('reads the top-level name, quoted or not', () {
      expect(
        packageNameFromPubspec('name: my_pkg\nversion: 1.0.0\n'),
        'my_pkg',
      );
      expect(packageNameFromPubspec("name: 'my_pkg'\n"), 'my_pkg');
      expect(packageNameFromPubspec('name: "my_pkg"\n'), 'my_pkg');
    });

    test('ignores an indented name', () {
      expect(
        packageNameFromPubspec('dependencies:\n  name: other\nname: my_pkg\n'),
        'my_pkg',
      );
    });

    test('throws when there is none', () {
      expect(
        () => packageNameFromPubspec('version: 1.0.0\n'),
        throwsFormatException,
      );
    });
  });

  group('PubLimitCheck.status', () {
    PubLimitCheck check(int bytes, {int? warnAt = 100}) => PubLimitCheck(
      path: 'CHANGELOG.md',
      bytes: bytes,
      limit: 200,
      warnAt: warnAt,
    );

    // pub.dev compares with `>`: exactly the limit is accepted.
    test('the limit itself is accepted, one byte more is not', () {
      expect(check(200).status, PubLimitStatus.near);
      expect(check(201).status, PubLimitStatus.over);
    });

    test('warns only past the warning size', () {
      expect(check(100).status, PubLimitStatus.ok);
      expect(check(101).status, PubLimitStatus.near);
    });

    test('never warns without a warning size', () {
      expect(check(200, warnAt: null).status, PubLimitStatus.ok);
      expect(check(201, warnAt: null).status, PubLimitStatus.over);
    });
  });

  group('collectPubLimitChecks', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('pub_limits_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    void write(String path, String content) => File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    test('measures what exists, and only that', () {
      write('pubspec.yaml', 'name: pkg\n');
      write('README.md', 'readme');
      write('CHANGELOG.md', 'changes');

      final checks = collectPubLimitChecks(dir);

      expect(checks.map((c) => c.path), [
        'pubspec.yaml',
        'README.md',
        'CHANGELOG.md',
      ]);
      expect(checks.first.limit, pubspecLimit);
      expect(checks.first.warnAt, isNull);
      expect(checks[1].limit, pubContentLimit);
      expect(checks[1].warnAt, pubContentWarnAt);
      expect(checks[1].bytes, 6);
    });

    // Which candidate pub.dev reads depends on .pubignore, which this does not
    // evaluate — so every candidate present is measured.
    test('measures every example candidate present, not just the first', () {
      write('pubspec.yaml', 'name: pkg\n');
      write('example/lib/main.dart', 'void main() {}\n');
      write('example/README.md', '# Example\n');

      expect(collectPubLimitChecks(dir).map((c) => c.path), [
        'pubspec.yaml',
        'example/lib/main.dart',
        'example/README.md',
      ]);
    });

    // The failure a character count would hide: every `é` is two bytes in
    // UTF-8, so this file is under the limit in characters and over it in
    // bytes — and pub.dev counts bytes.
    test('measures bytes, not characters', () {
      final chars = pubContentLimit ~/ 2 + 1;
      write('pubspec.yaml', 'name: pkg\n');
      write('CHANGELOG.md', 'é' * chars);

      final changelog = collectPubLimitChecks(
        dir,
      ).singleWhere((c) => c.path == 'CHANGELOG.md');

      expect(chars, lessThan(pubContentLimit));
      expect(changelog.bytes, chars * 2);
      expect(changelog.status, PubLimitStatus.over);
    });
  });

  group('pubLimitAdvice', () {
    test('tells a CHANGELOG how to shrink without breaking its links', () {
      final advice = pubLimitAdvice(
        const PubLimitCheck(path: 'CHANGELOG.md', bytes: 1, limit: 1),
      );
      expect(advice, contains('.pubignore'));
      expect(advice, contains('absolute URL'));
    });
  });
}
