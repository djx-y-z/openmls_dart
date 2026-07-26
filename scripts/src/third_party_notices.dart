/// Generation and verification of the bundled third-party notice inventory.
///
/// The shipped native library is statically linked against its whole Rust
/// dependency tree. MIT, BSD and Apache-2.0 all require the corresponding
/// copyright and licence notices to travel with a binary distribution, and
/// Flutter's `LicenseRegistry` cannot help here: it aggregates `LICENSE` files
/// of pub packages, and Rust crates are not pub packages.
///
/// The inventory is generated from the resolved dependency graph rather than
/// from `Cargo.lock` wholesale: only crates that actually link into a shipped
/// artifact belong in it. Dev- and build-only dependencies (test harnesses,
/// proc-macro toolchains) are excluded by `cargo tree --edges normal`.
library;

import 'dart:convert';
import 'dart:io';

import 'common.dart';

/// Rust targets whose dependency graphs are unioned into the inventory.
///
/// Must stay in sync with the platforms built by the native release workflow —
/// a target missing here silently drops the crates unique to it (for example
/// `idb`/`web-sys` on wasm32, or `rusqlite` on native).
const releaseTargets = <String>[
  'x86_64-unknown-linux-gnu',
  'aarch64-unknown-linux-gnu',
  'aarch64-apple-darwin',
  'x86_64-apple-darwin',
  'x86_64-pc-windows-msvc',
  'aarch64-apple-ios',
  'aarch64-apple-ios-sim',
  'x86_64-apple-ios',
  'aarch64-linux-android',
  'armv7-linux-androideabi',
  'x86_64-linux-android',
  'wasm32-unknown-unknown',
];

/// Filenames a crate may use for its licence text, in preference order.
const _licenceFilePatterns = <String>[
  'LICENSE',
  'LICENSE.md',
  'LICENSE.txt',
  'LICENCE',
  'LICENCE.md',
  'LICENCE.txt',
  'COPYING',
  'COPYING.md',
  'UNLICENSE',
];

/// One crate that links into a shipped artifact.
class CrateNotice {
  const CrateNotice({
    required this.name,
    required this.version,
    required this.spdx,
    required this.licenceTexts,
  });

  final String name;
  final String version;

  /// SPDX expression from the crate manifest, or `null` when it declares none.
  final String? spdx;

  /// Licence texts shipped by the crate, keyed by filename and sorted by key.
  ///
  /// Empty when the crate ships no licence file; the SPDX expression is then
  /// the only attribution available.
  final Map<String, String> licenceTexts;

  String get id => '$name@$version';
}

/// Runs `cargo tree` per release target and returns the union of linked crates.
///
/// Returns `name@version` identifiers. `--edges normal` drops dev- and
/// build-dependencies, which are compiled but never linked into the artifact.
Set<String> collectLinkedCrates({
  required String manifestPath,
  List<String> targets = releaseTargets,
  void Function(String)? onProgress,
}) {
  final crates = <String>{};

  for (final target in targets) {
    onProgress?.call(target);
    final result = Process.runSync('cargo', [
      'tree',
      '--manifest-path',
      manifestPath,
      '--edges',
      'normal',
      '--target',
      target,
      '--prefix',
      'none',
    ]);
    if (result.exitCode != 0) {
      throw Exception(
        'cargo tree failed for $target (exit ${result.exitCode}):\n'
        '${result.stderr}',
      );
    }
    crates.addAll(parseCargoTree(result.stdout as String));
  }

  return crates;
}

/// Extracts `name@version` identifiers from `cargo tree --prefix none` output.
///
/// Lines look like `serde v1.0.0`, optionally followed by a source in
/// parentheses (git dependencies) or a ` (*)` de-duplication marker.
Set<String> parseCargoTree(String stdout) {
  final pattern = RegExp(r'^(\S+) v(\d[^\s]*)');
  final crates = <String>{};
  for (final line in const LineSplitter().convert(stdout)) {
    final match = pattern.firstMatch(line.trim());
    if (match != null) {
      crates.add('${match.group(1)}@${match.group(2)}');
    }
  }
  return crates;
}

/// Reads crate metadata (SPDX expression + on-disk location) via `cargo metadata`.
Map<String, CrateNotice> loadCrateNotices({
  required String manifestPath,
  required Set<String> linkedCrates,
}) {
  final result = Process.runSync('cargo', [
    'metadata',
    '--manifest-path',
    manifestPath,
    '--format-version',
    '1',
  ]);
  if (result.exitCode != 0) {
    throw Exception(
      'cargo metadata failed (exit ${result.exitCode}):\n${result.stderr}',
    );
  }

  final metadata = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  final packages = metadata['packages'] as List<dynamic>;
  final notices = <String, CrateNotice>{};
  final unpackedMissing = <String>[];
  final ownCrates = <String>{};

  // This repository's own crates are not third parties: they are covered by the
  // package LICENSE. Excluding them also decouples the inventory from the crate
  // version, so a release bump does not invalidate it.
  //
  // Identified by manifest location rather than by parsing `workspace_members`,
  // whose string format cargo has changed between releases.
  final workspaceRoot = metadata['workspace_root'] as String;

  for (final entry in packages) {
    final package = entry as Map<String, dynamic>;
    final name = package['name'] as String;
    final version = package['version'] as String;
    final id = '$name@$version';
    if (!linkedCrates.contains(id)) continue;

    final manifestPath = package['manifest_path'] as String;
    if (isWithin(workspaceRoot, manifestPath)) {
      ownCrates.add(id);
      continue;
    }

    final crateDir = File(manifestPath).parent;
    if (!crateDir.existsSync()) {
      unpackedMissing.add(id);
      continue;
    }

    notices[id] = CrateNotice(
      name: name,
      version: version,
      spdx: package['license'] as String?,
      licenceTexts: _readLicenceTexts(
        crateDir,
        declaredFile: package['license_file'] as String?,
      ),
    );
  }

  // Without the extracted sources there are no licence texts to read, and the
  // inventory would silently degrade to SPDX expressions only. Fail instead.
  if (unpackedMissing.isNotEmpty) {
    final sorted = unpackedMissing.toList()..sort();
    throw Exception(
      'Source directory missing for ${unpackedMissing.length} crate(s): '
      '${sorted.take(5).join(', ')}${unpackedMissing.length > 5 ? ', …' : ''}. '
      'Run `cargo fetch --manifest-path rust/Cargo.toml` and retry.',
    );
  }

  // Every linked crate must be either inventoried or deliberately skipped as
  // our own; a gap means attribution would be silently omitted.
  final unaccounted = linkedCrates.difference({...notices.keys, ...ownCrates});
  if (unaccounted.isNotEmpty) {
    final sorted = unaccounted.toList()..sort();
    throw Exception(
      'No cargo metadata for ${unaccounted.length} linked crate(s): '
      '${sorted.take(5).join(', ')}${unaccounted.length > 5 ? ', …' : ''}',
    );
  }

  return notices;
}

/// Whether [child] lives under directory [parent]. Both must be absolute.
bool isWithin(String parent, String child) {
  final separator = Platform.pathSeparator;
  final normalized = parent.endsWith(separator) ? parent : '$parent$separator';
  return child.startsWith(normalized);
}

/// Collects licence texts shipped inside a crate's source directory.
Map<String, String> _readLicenceTexts(
  Directory crateDir, {
  String? declaredFile,
}) {
  final texts = <String, String>{};
  if (!crateDir.existsSync()) return texts;

  final candidates = <String>[
    if (declaredFile != null) declaredFile,
    ..._licenceFilePatterns,
  ];

  // A crate may ship several (LICENSE-MIT + LICENSE-APACHE); take every file
  // whose name starts with a known pattern so dual licences stay complete.
  for (final file in crateDir.listSync().whereType<File>()) {
    final base = file.uri.pathSegments.last;
    final matches = candidates.any(
      (candidate) => base.toLowerCase().startsWith(candidate.toLowerCase()),
    );
    if (!matches) continue;
    try {
      final content = file.readAsStringSync().trim();
      if (content.isNotEmpty) texts[base] = content;
    } on FileSystemException {
      // Unreadable or non-UTF8 licence file: fall back to the SPDX expression.
    }
  }

  return Map.fromEntries(
    texts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

/// Renders the notice inventory.
///
/// Licence texts are pooled and referenced by index rather than repeated per
/// crate: the Apache-2.0 text alone is ~10 KB and appears in over a hundred
/// crates, which inflates the file roughly fivefold for no added information.
///
/// Output is deterministic — crates sorted by `name@version`, texts sorted by
/// content, no timestamps — so `--check` can diff it byte-for-byte.
String renderNotices({
  required String packageName,
  required String crateName,
  required Map<String, CrateNotice> notices,
}) {
  final ids = notices.keys.toList()..sort();

  // Pool distinct texts, then index them in sorted order so the numbering is
  // stable across runs and machines.
  final references = <String, int>{};
  final users = <String, List<String>>{};
  for (final id in ids) {
    for (final entry in notices[id]!.licenceTexts.entries) {
      (users[entry.value] ??= []).add(id);
    }
  }
  final distinctTexts = users.keys.toList()..sort();
  for (var i = 0; i < distinctTexts.length; i++) {
    references[distinctTexts[i]] = i + 1;
  }

  final buffer = StringBuffer()
    ..writeln('THIRD-PARTY SOFTWARE NOTICES')
    ..writeln()
    ..writeln(
      'The $packageName package ships a prebuilt native library ($crateName) '
      'that is',
    )
    ..writeln(
      'statically linked against the Rust crates listed below. Their licences '
      'require',
    )
    ..writeln(
      'these notices to accompany any binary distribution, including an '
      'application',
    )
    ..writeln('that embeds the library.')
    ..writeln()
    ..writeln(
      'Generated from the resolved dependency graph '
      '(cargo tree --edges normal) across',
    )
    ..writeln(
      'every released target, so build- and dev-only dependencies are '
      'excluded. Regenerate',
    )
    ..writeln('with `make third-party-notices`.')
    ..writeln()
    ..writeln(
      'Each crate below lists its SPDX expression and the licence texts it '
      'ships, by',
    )
    ..writeln(
      'reference into the LICENCE TEXTS section at the end. Identical texts '
      'are pooled',
    )
    ..writeln('rather than repeated.')
    ..writeln()
    ..writeln('Crates listed: ${ids.length}')
    ..writeln('Distinct licence texts: ${distinctTexts.length}')
    ..writeln()
    ..writeln('=' * 78)
    ..writeln('CRATES')
    ..writeln('=' * 78);

  for (final id in ids) {
    final notice = notices[id]!;
    buffer
      ..writeln()
      ..writeln('${notice.name} ${notice.version}')
      ..writeln(
        '  License: ${notice.spdx ?? '(not declared in crate manifest)'}',
      );

    if (notice.licenceTexts.isEmpty) {
      buffer.writeln(
        '  Texts:   (crate ships no licence file; SPDX expression above is '
        'the declared licence)',
      );
      continue;
    }

    final refs = notice.licenceTexts.entries
        .map((e) => '${e.key} [T${references[e.value]}]')
        .join(', ');
    buffer.writeln('  Texts:   $refs');
  }

  buffer
    ..writeln()
    ..writeln('=' * 78)
    ..writeln('LICENCE TEXTS')
    ..writeln('=' * 78);

  for (final text in distinctTexts) {
    final index = references[text]!;
    final referrers = users[text]!;
    final names = (referrers.toSet().toList()..sort()).join(', ');
    buffer
      ..writeln()
      ..writeln('-' * 78)
      ..writeln('[T$index] referenced by ${referrers.length} crate(s)')
      ..writeln('-' * 78)
      ..writeln()
      ..writeln('Crates: $names')
      ..writeln()
      ..writeln(text);
  }

  return buffer.toString();
}

/// Generates the inventory for this repository.
String generateNotices({
  required String manifestPath,
  required String packageName,
  required String crateName,
  void Function(String)? onProgress,
}) {
  final linked = collectLinkedCrates(
    manifestPath: manifestPath,
    onProgress: onProgress,
  );
  final notices = loadCrateNotices(
    manifestPath: manifestPath,
    linkedCrates: linked,
  );

  return renderNotices(
    packageName: packageName,
    crateName: crateName,
    notices: notices,
  );
}

/// Compares generated output against a committed file.
///
/// Returns null when they match, or a human-readable description of the drift.
String? describeDrift({required String generated, required File committed}) {
  if (!committed.existsSync()) {
    return 'Missing ${committed.path}. Run `make third-party-notices`.';
  }
  final onDisk = committed.readAsStringSync();
  if (onDisk == generated) return null;

  final onDiskCount = _crateCount(onDisk);
  final generatedCount = _crateCount(generated);
  final detail = onDiskCount == generatedCount
      ? 'same crate count ($generatedCount), but the contents differ — a '
            'crate version, licence text or the file itself changed'
      : 'lists $onDiskCount crates, dependency graph resolves to '
            '$generatedCount';
  return 'Committed ${committed.path} is out of date ($detail). '
      'Run `make third-party-notices` and commit the result.';
}

int _crateCount(String notices) {
  final match = RegExp(
    r'^Crates listed: (\d+)$',
    multiLine: true,
  ).firstMatch(notices);
  return match == null ? -1 : int.parse(match.group(1)!);
}

/// Absolute path of the notice file for this repository.
String noticesPath() => '${getPackageDir().path}/THIRD_PARTY_NOTICES.txt';

/// Generates the inventory for this repository using its own paths and names.
String generateNoticesForRepo({void Function(String)? onProgress}) =>
    generateNotices(
      manifestPath: '${getPackageDir().path}/rust/Cargo.toml',
      packageName: 'openmls',
      crateName: getCrateName(),
      onProgress: onProgress,
    );

/// Fails when the committed inventory does not match the dependency graph.
///
/// Called from both release stages: the notice file ships inside every native
/// release archive and inside the published package, and neither a pushed tag
/// nor a pub.dev publish can be taken back.
void assertNoticesCurrent() {
  final drift = describeDrift(
    generated: generateNoticesForRepo(),
    committed: File(noticesPath()),
  );
  if (drift != null) {
    throw Exception(
      '$drift This file ships in the release archives and in the published '
      'package, so the release is aborted.',
    );
  }
}
