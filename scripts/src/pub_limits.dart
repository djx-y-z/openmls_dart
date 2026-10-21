// The upload limits pub.dev enforces that `dart pub publish --dry-run` does not.
//
// pub.dev reads four files out of an uploaded archive to build the package page
// — README.md, CHANGELOG.md, LICENSE and the first example it finds — and
// refuses the upload when any of them is larger than 256 KiB, or when
// pubspec.yaml is larger than 128 KiB (`maxContentLength` and the pubspec check
// in pub-dev's `pkg/pub_package_reader`). The dry-run measures none of them, so
// the first sign is the upload failing in publish.yml: after the tag is pushed,
// when the version can no longer be used. A CHANGELOG grows with every release
// and crosses the line without anybody touching the limit — that is how this
// was found, as a refused upload.
//
// Every example candidate that exists is measured, not only the first. pub.dev
// reads the first candidate IN THE ARCHIVE, and which one that is depends on
// what .pubignore keeps out. Measuring all of them can only fail on a file
// pub.dev would not have read, never pass one it refuses.
//
// Sizes are bytes, which is what pub.dev compares. A character count is smaller
// for any text outside ASCII and would pass files pub.dev refuses.
//
// Only [collectPubLimitChecks] touches the disk; everything else takes values,
// so the rules are testable without a fixture tree.
library;

import 'dart:io';

/// The limit pub.dev puts on README.md, CHANGELOG.md, LICENSE and the example.
const pubContentLimit = 256 * 1024;

/// The limit pub.dev puts on pubspec.yaml.
const pubspecLimit = 128 * 1024;

/// Where a file under [pubContentLimit] starts drawing a warning. A CHANGELOG
/// can grow by tens of KB in one release, so this leaves room for a release or
/// two — time to move old sections out before the limit is what reports it.
const pubContentWarnAt = 200 * 1024;

/// The files pub.dev measures against [pubContentLimit], in the order it looks
/// for them (`file_names.dart` in pub-dev's `pkg/pub_package_reader`). The
/// example it reads is the first `example/` entry the archive contains.
List<String> pubContentFiles(String packageName) => [
  'README.md',
  'CHANGELOG.md',
  'LICENSE',
  'example/example.md',
  'example/lib/main.dart',
  'example/main.dart',
  'example/lib/$packageName.dart',
  'example/$packageName.dart',
  'example/lib/${packageName}_example.dart',
  'example/${packageName}_example.dart',
  'example/lib/example.dart',
  'example/example.dart',
  'example/README.md',
];

/// The package name from pubspec.yaml's top-level `name:`.
String packageNameFromPubspec(String pubspec) {
  final match = RegExp(
    r'''^name:\s*['"]?([A-Za-z0-9_]+)['"]?\s*$''',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) {
    throw const FormatException('pubspec.yaml has no top-level `name:`.');
  }
  return match.group(1)!;
}

/// How one file measures against its limit.
enum PubLimitStatus {
  /// Within the limit, and below the warning size if it has one.
  ok,

  /// Within the limit but past its warning size.
  near,

  /// Over the limit: pub.dev refuses the upload.
  over,
}

/// One file pub.dev limits, as measured.
class PubLimitCheck {
  const PubLimitCheck({
    required this.path,
    required this.bytes,
    required this.limit,
    this.warnAt,
  });

  /// Path relative to the package root.
  final String path;

  /// Size on disk, in bytes.
  final int bytes;

  /// The most bytes pub.dev accepts for this file.
  final int limit;

  /// The size past which the file is [PubLimitStatus.near]; null for none.
  final int? warnAt;

  /// pub.dev refuses only MORE than the limit: a file of exactly [limit]
  /// bytes is accepted.
  PubLimitStatus get status {
    if (bytes > limit) return PubLimitStatus.over;
    final warnAt = this.warnAt;
    if (warnAt != null && bytes > warnAt) return PubLimitStatus.near;
    return PubLimitStatus.ok;
  }

  @override
  String toString() => '$path: $bytes bytes; pub.dev accepts at most $limit';
}

/// What to do about [check] once it is near or over its limit.
String pubLimitAdvice(PubLimitCheck check) => check.path == 'CHANGELOG.md'
    ? 'Move what the package page does not need — the oldest released '
          'sections first — into a file .pubignore keeps out of the archive, '
          'and link to it by absolute URL: a relative link does not resolve '
          'on pub.dev.'
    : 'pub.dev reads ${check.path} into the package page and measures it as '
          'it is in the archive.';

/// Measures every file under [packageDir] that pub.dev limits and that exists.
List<PubLimitCheck> collectPubLimitChecks(Directory packageDir) {
  File file(String path) => File('${packageDir.path}/$path');
  final pubspec = file('pubspec.yaml');
  final name = packageNameFromPubspec(pubspec.readAsStringSync());
  return [
    PubLimitCheck(
      path: 'pubspec.yaml',
      bytes: pubspec.lengthSync(),
      limit: pubspecLimit,
    ),
    for (final path in pubContentFiles(name))
      if (file(path).existsSync())
        PubLimitCheck(
          path: path,
          bytes: file(path).lengthSync(),
          limit: pubContentLimit,
          warnAt: pubContentWarnAt,
        ),
  ];
}
