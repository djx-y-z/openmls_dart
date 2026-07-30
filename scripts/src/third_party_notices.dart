/// Generation and verification of the bundled third-party notice inventory.
///
/// The shipped native library is statically linked against its whole Rust
/// dependency tree. MIT, BSD and Apache-2.0 all require the corresponding
/// copyright and licence notices to travel with a binary distribution, and
/// Flutter's `LicenseRegistry` cannot help here: it aggregates `LICENSE` files
/// of pub packages, and Rust crates are not pub packages.
///
/// The inventory is generated from the resolved dependency graph rather than
/// from `Cargo.lock` wholesale: only crates that participate in building a
/// shipped artifact belong in it. Dev-dependencies (test harnesses, benchmark
/// tooling) are excluded by `cargo tree --edges normal,build`.
library;

import 'dart:convert';
import 'dart:io';

import 'common.dart';
import 'spdx_license_texts.dart';

/// Rust targets whose dependency graphs are unioned into the inventory.
///
/// Must stay in sync with the `rust_target` values in
/// `.github/workflows/build-openmls.yml` — a target missing here
/// silently drops the crates unique to it, which is exactly where
/// platform-specific dependencies live.
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

/// How deep to look inside a crate directory for licence files.
///
/// A crate that vendors foreign native code keeps that code's licence beside
/// the vendored tree rather than at the crate root — `sqlcipher/LICENSE` in
/// `libsqlite3-sys`, `openssl/LICENSE.txt` in `openssl-src`. A flat scan of the
/// crate root misses exactly the licences that matter most, because vendored C
/// is what actually ends up compiled into the binary.
const _maxLicenceDepth = 3;

/// How far up to look for a git dependency's licence.
///
/// A crate published from a git workspace keeps its licence at the repository
/// root, while cargo points at the member directory — every crate taken from
/// such a repository would otherwise be listed with no text at all.
/// Never applied to registry crates: their parent is the shared `registry/src`
/// directory, where a licence file would belong to some unrelated crate.
const _maxGitParentDepth = 3;

/// One crate that participates in building a shipped artifact.
class CrateNotice {
  const CrateNotice({
    required this.name,
    required this.version,
    required this.spdx,
    required this.licenceTexts,
    this.repository,
    this.authors = const [],
  });

  final String name;
  final String version;

  /// SPDX expression from the crate manifest, or `null` when it declares none.
  final String? spdx;

  /// Licence texts shipped by the crate, keyed by path relative to the crate
  /// directory and sorted by key.
  ///
  /// Empty when the crate ships no licence file; a canonical text is then
  /// supplied from [spdx] where the licence allows it.
  final Map<String, String> licenceTexts;

  /// Repository URL from the crate manifest, where one is declared.
  final String? repository;

  /// Authors from the crate manifest; the only attribution available for a
  /// crate that ships no licence file.
  final List<String> authors;

  String get id => '$name@$version';
}

/// Runs `cargo tree` per release target and returns the union of crates.
///
/// Returns `name@version` identifiers.
///
/// `--edges normal,build` keeps build-dependencies deliberately. That is how
/// vendored native code enters the binary: a `*-src` crate carrying C sources
/// is a build-dependency of its `*-sys` wrapper, compiled by a build script and
/// statically linked. No mechanical rule separates such a crate from a pure
/// build tool, so the inventory errs towards listing both — it is already
/// inclusive in the same direction, since proc-macro crates are normal edges
/// and contribute no code either. Dev-dependencies stay excluded.
///
/// `--locked` matters more than it looks: without it a stale `Cargo.lock` lets
/// cargo silently re-resolve and rewrite the graph, so the same commit could
/// produce different inventories on different machines. This turns that into a
/// loud failure.
///
/// No per-target query is reproducible across machines. `--target <triple>`
/// filters the *target* dependencies by that triple, but everything compiled
/// for the build machine — build-dependencies **and proc-macro subtrees** — is
/// resolved for the **host**. Both axes bite in practice: `rustix`, reached
/// through `prost-build` → `tempfile`, selects `errno` on a macOS host and
/// `linux-raw-sys` on a Linux one; and `winapi` hangs off `ansi_term` inside a
/// proc-macro crate, so it is visible only from a Windows host. The inventory
/// then changes with the machine — sometimes swapping one crate for another,
/// which leaves the crate count identical and the contents different — and CI
/// rejects a file that was correct where it was generated.
///
/// `--target all` is the only query cargo offers that applies no platform
/// filtering at all, so the crate set is taken from it. It is a superset of
/// every per-target result, so it over-attributes: the extra entries are build
/// tooling and platform-gated crates a given build never links. That is the
/// deliberate trade — a byte-exact check is only viable against output that
/// does not change with the machine. The per-target sweep is
/// kept because it is the only thing that fails when a declared release target
/// stops resolving, which is what keeps [releaseTargets] honest.
Set<String> collectLinkedCrates({
  required String manifestPath,
  List<String> targets = releaseTargets,
  void Function(String)? onProgress,
}) {
  if (targets.isEmpty) {
    throw Exception(
      'No release targets configured; the inventory would come out empty. '
      'Populate releaseTargets with the platforms this package builds for.',
    );
  }

  final crates = <String>{};

  for (final target in targets) {
    onProgress?.call(target);
    crates.addAll(
      _cargoTree(manifestPath, edges: 'normal,build', target: target),
    );
  }

  // The set that actually decides the inventory. Unioned rather than
  // substituted so the pass can only widen it, though it subsumes the sweep
  // above by construction: anything visible for one triple under host
  // filtering is visible with no filtering at all.
  onProgress?.call('all platforms (host-independent)');
  crates.addAll(_cargoTree(manifestPath, edges: 'normal,build', target: 'all'));

  return crates;
}

/// One `cargo tree` invocation, parsed into `name@version` identifiers.
Set<String> _cargoTree(
  String manifestPath, {
  required String edges,
  required String target,
}) {
  final result = Process.runSync('cargo', [
    'tree',
    '--manifest-path',
    manifestPath,
    '--locked',
    '--edges',
    edges,
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
  return parseCargoTree(result.stdout as String);
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
    '--locked',
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

    final source = package['source'] as String? ?? '';
    notices[id] = CrateNotice(
      name: name,
      version: version,
      spdx: package['license'] as String?,
      repository: package['repository'] as String?,
      authors: (package['authors'] as List<dynamic>? ?? [])
          .map((a) => a as String)
          .toList(),
      licenceTexts: readLicenceTexts(
        crateDir,
        declaredFile: package['license_file'] as String?,
        gitSourced: source.startsWith('git+'),
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

/// Collects licence texts belonging to a crate.
///
/// Scans the crate directory down to [_maxLicenceDepth] so licences shipped
/// alongside vendored native code are found, and — for git dependencies only —
/// walks up to the repository root when the member directory holds none.
///
/// Keys are paths relative to the crate directory, always with `/` separators
/// so a Windows run produces the same bytes as a POSIX one.
Map<String, String> readLicenceTexts(
  Directory crateDir, {
  String? declaredFile,
  bool gitSourced = false,
}) {
  final texts = <String, String>{};
  _collectLicenceFiles(
    crateDir,
    crateDir.path,
    texts,
    declaredFile: declaredFile,
    maxDepth: _maxLicenceDepth,
  );

  if (texts.isEmpty && gitSourced) {
    var dir = crateDir;
    for (var up = 1; up <= _maxGitParentDepth; up++) {
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;

      // Flat scan only: recursing from a repository root would sweep in the
      // licences of unrelated workspace members.
      final found = <String, String>{};
      _collectLicenceFiles(dir, dir.path, found, maxDepth: 0);
      if (found.isNotEmpty) {
        final prefix = '../' * up;
        found.forEach((key, value) => texts['$prefix$key'] = value);
        break;
      }
    }
  }

  return Map.fromEntries(
    texts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

void _collectLicenceFiles(
  Directory dir,
  String relativeTo,
  Map<String, String> out, {
  required int maxDepth,
  String? declaredFile,
  int depth = 0,
}) {
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync();
  } on FileSystemException {
    return;
  }

  final candidates = <String>[
    if (declaredFile != null) declaredFile,
    ..._licenceFilePatterns,
  ];

  for (final entity in entries) {
    if (entity is Directory) {
      if (depth < maxDepth) {
        _collectLicenceFiles(
          entity,
          relativeTo,
          out,
          maxDepth: maxDepth,
          declaredFile: declaredFile,
          depth: depth + 1,
        );
      }
      continue;
    }
    if (entity is! File) continue;

    // A crate may ship several (LICENSE-MIT + LICENSE-APACHE); take every file
    // whose name starts with a known pattern so dual licences stay complete.
    final base = entity.uri.pathSegments.last;
    final matches = candidates.any(
      (candidate) => base.toLowerCase().startsWith(candidate.toLowerCase()),
    );
    if (!matches) continue;

    try {
      final content = entity.readAsStringSync().trim();
      if (content.isNotEmpty) {
        out[relativeKey(entity.path, relativeTo)] = content;
      }
    } on FileSystemException {
      // Unreadable or non-UTF8 licence file: fall back to the SPDX expression.
    }
  }
}

/// Path of [path] relative to [root], normalised to `/` separators.
String relativeKey(String path, String root) {
  final stripped = path.startsWith(root) ? path.substring(root.length) : path;
  final slashed = stripped.replaceAll(r'\', '/');
  return slashed.startsWith('/') ? slashed.substring(1) : slashed;
}

/// Licence identifiers named by an SPDX expression, in declaration order.
///
/// Handles the pre-SPDX `MIT/Apache-2.0` spelling that older crates still use
/// alongside the `MIT OR Apache-2.0` form.
List<String> parseSpdxIds(String expression) => expression
    .replaceAll('(', ' ')
    .replaceAll(')', ' ')
    .replaceAll('/', ' ')
    .split(RegExp(r'\s+'))
    .where(
      (token) =>
          token.isNotEmpty &&
          token != 'OR' &&
          token != 'AND' &&
          token != 'WITH',
    )
    .toList();

/// Whether [key] names a licence belonging to the crate itself.
///
/// A bare filename is the crate's own licence, and so is one reached by walking
/// up to a git repository root. A nested path is not: it belongs to code the
/// crate vendors, and delivering it says nothing about the crate's own grant —
/// `dart-sys` ships only `dart-sdk/LICENSE`, the licence of the vendored Dart
/// SDK headers, and nothing for its own MIT/Apache-2.0 offer.
bool isOwnLicenceKey(String key) => !key.contains('/') || key.startsWith('../');

/// A canonical licence text supplied for a crate that ships none.
typedef SuppliedLicence = ({String spdx, String text, bool reconstructed});

/// Canonical text to supply for [notice], or null when none can be.
///
/// Prefers a licence whose text is invariant (Apache-2.0, MPL-2.0): supplying
/// it reproduces exactly what the crate declared. Only when no operand offers
/// one does it fall back to MIT, whose copyright line has to be composed from
/// crate metadata and is marked as reconstructed in the output.
SuppliedLicence? suppliedLicenceFor(CrateNotice notice) {
  final spdx = notice.spdx;
  if (spdx == null) return null;

  // `WITH` modifies the identifier before it (an LLVM exception, say), so the
  // plain text of that identifier is not the licence the crate granted.
  if (RegExp(r'\bWITH\b').hasMatch(spdx)) return null;

  final ids = parseSpdxIds(spdx);
  for (final id in ids) {
    final text = canonicalTextFor(id);
    if (text != null) {
      return (spdx: id, text: text, reconstructed: false);
    }
  }
  if (ids.contains('MIT')) {
    return (spdx: 'MIT', text: _mitTextFor(notice), reconstructed: true);
  }
  return null;
}

String _mitTextFor(CrateNotice notice) {
  final attribution = notice.authors.isNotEmpty
      ? 'Copyright (c) ${notice.authors.join(', ')}'
      : 'Copyright holders: not stated in the crate manifest'
            '${notice.repository == null ? '' : '; see ${notice.repository}'}';
  return 'MIT License\n\n$attribution\n\n$mitTerms';
}

/// Renders the notice inventory.
///
/// Licence texts are pooled and referenced by index rather than repeated per
/// crate: the Apache-2.0 text alone is ~10 KB and appears in over a hundred
/// crates, which inflates the file roughly fivefold for no added information.
///
/// Texts a crate ships itself are pooled as `[Tn]`; canonical texts supplied
/// for crates that ship none are pooled separately as `[Cn]`, so the document
/// never blurs what upstream delivered with what this generator filled in.
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
  final shippedUsers = <String, List<String>>{};
  final suppliedUsers = <String, List<String>>{};
  final supplied = <String, SuppliedLicence>{};
  final suppliedKinds = <String, SuppliedLicence>{};
  for (final id in ids) {
    final notice = notices[id]!;
    for (final text in notice.licenceTexts.values.toSet()) {
      (shippedUsers[text] ??= []).add(id);
    }
    if (notice.licenceTexts.keys.any(isOwnLicenceKey)) continue;

    final licence = suppliedLicenceFor(notice);
    if (licence == null) continue;
    supplied[id] = licence;
    suppliedKinds[licence.text] = licence;
    (suppliedUsers[licence.text] ??= []).add(id);
  }

  final shippedTexts = shippedUsers.keys.toList()..sort();
  final suppliedTexts = suppliedUsers.keys.toList()..sort();
  final shippedRefs = {
    for (var i = 0; i < shippedTexts.length; i++) shippedTexts[i]: i + 1,
  };
  final suppliedRefs = {
    for (var i = 0; i < suppliedTexts.length; i++) suppliedTexts[i]: i + 1,
  };

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
      'Generated from the resolved dependency graph, with no platform '
      'filtering',
    )
    ..writeln(
      '(cargo tree --edges normal,build --target all), so the same commit '
      'yields the',
    )
    ..writeln(
      'same inventory on any machine: build-dependencies and proc-macro '
      'subtrees are',
    )
    ..writeln(
      'otherwise resolved for the build host. Build edges are kept because '
      'that is how',
    )
    ..writeln(
      'vendored native code reaches the binary — a *-src crate carrying C '
      'sources is',
    )
    ..writeln(
      'a build-dependency of its *-sys wrapper — and no mechanical rule tells '
      'such a',
    )
    ..writeln(
      'crate apart from a pure build tool. The list is therefore inclusive: a '
      'few',
    )
    ..writeln(
      'entries only run at build time. Dev-dependencies are excluded. '
      'Regenerate with',
    )
    ..writeln('`make third-party-notices`.')
    ..writeln()
    ..writeln(
      'Each crate lists its SPDX expression and the licence texts it ships, by '
      'reference',
    )
    ..writeln(
      'into LICENCE TEXTS. Where a crate ships no licence file, the canonical '
      'text of',
    )
    ..writeln(
      'the licence it declares is supplied instead, referenced into CANONICAL '
      'LICENCE',
    )
    ..writeln('TEXTS. Identical texts are pooled rather than repeated.')
    ..writeln()
    ..writeln('Crates listed: ${ids.length}')
    ..writeln('Distinct licence texts: ${shippedTexts.length}')
    ..writeln('Canonical licence texts supplied: ${suppliedTexts.length}')
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

    if (notice.licenceTexts.isNotEmpty) {
      final refs = notice.licenceTexts.entries
          .map((e) => '${e.key} [T${shippedRefs[e.value]}]')
          .join(', ');
      buffer.writeln('  Texts:   $refs');
    }

    final licence = supplied[id];
    if (licence != null) {
      final kind = licence.reconstructed ? 'terms' : 'text';
      buffer.writeln(
        '  Notice:  ships no licence file of its own; canonical '
        '${licence.spdx} $kind [C${suppliedRefs[licence.text]}]',
      );
    } else if (notice.licenceTexts.isEmpty) {
      buffer
        ..writeln(
          '  Notice:  ships no licence file, and the licence it declares '
          'embeds a',
        )
        ..writeln(
          '           copyright line that cannot be recovered — the SPDX '
          'expression',
        )
        ..writeln('           above is the whole of the declared licence');
    }

    if (notice.repository != null &&
        (licence != null || notice.licenceTexts.isEmpty)) {
      buffer.writeln('  Source:  ${notice.repository}');
    }
  }

  _writePool(
    buffer,
    title: 'LICENCE TEXTS',
    preamble: 'Texts exactly as shipped by the crates that reference them.',
    prefix: 'T',
    texts: shippedTexts,
    refs: shippedRefs,
    users: shippedUsers,
    verb: 'referenced by',
  );

  if (suppliedTexts.isNotEmpty) {
    _writePool(
      buffer,
      title: 'CANONICAL LICENCE TEXTS',
      preamble:
          'These crates ship no licence file of their own. The canonical text '
          'of the licence\neach one declares is supplied here, so the '
          'inventory delivers the licence and not\nmerely its name.',
      prefix: 'C',
      texts: suppliedTexts,
      refs: suppliedRefs,
      users: suppliedUsers,
      verb: 'supplied for',
      annotate: (text) {
        final licence = suppliedKinds[text]!;
        return licence.reconstructed
            ? '${licence.spdx}, copyright line composed from crate metadata'
            : licence.spdx;
      },
    );
  }

  return buffer.toString();
}

void _writePool(
  StringBuffer buffer, {
  required String title,
  required String preamble,
  required String prefix,
  required String verb,
  required List<String> texts,
  required Map<String, int> refs,
  required Map<String, List<String>> users,
  String Function(String text)? annotate,
}) {
  buffer
    ..writeln()
    ..writeln('=' * 78)
    ..writeln(title)
    ..writeln('=' * 78)
    ..writeln()
    ..writeln(preamble);

  for (final text in texts) {
    final referrers = users[text]!.toSet().toList()..sort();
    final note = annotate == null ? '' : ' — ${annotate(text)}';
    buffer
      ..writeln()
      ..writeln('-' * 78)
      ..writeln(
        '[$prefix${refs[text]}] $verb ${referrers.length} crate(s)$note',
      )
      ..writeln('-' * 78)
      ..writeln()
      ..writeln('Crates:');
    for (final referrer in referrers) {
      buffer.writeln('  $referrer');
    }
    buffer
      ..writeln()
      ..writeln(text);
  }
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
///
/// The description names the lines that actually moved. This check normally
/// fails on a machine that cannot run the generator interactively — a CI log is
/// the whole diagnosis — and "the contents differ" sends the reader to bisect a
/// 400 KB file by hand. A swapped crate (see [collectLinkedCrates] on
/// host-dependent build edges) is invisible in the counts and obvious in one
/// line of diff.
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
  return 'Committed ${committed.path} is out of date ($detail).\n'
      '${_describeLineDrift(onDisk, generated)}'
      'Run `make third-party-notices` and commit the result.';
}

/// How many differing lines to quote from each side.
const _driftSamples = 5;

/// Renders the first divergence plus a sample of the lines unique to each side.
///
/// Set-based rather than a real diff: the file is sorted by construction, so
/// "only on one side" is the meaningful signal, and an LCS over ~10k lines buys
/// nothing here.
String _describeLineDrift(String onDisk, String generated) {
  final onDiskLines = const LineSplitter().convert(onDisk);
  final generatedLines = const LineSplitter().convert(generated);

  final buffer = StringBuffer();
  var i = 0;
  while (i < onDiskLines.length &&
      i < generatedLines.length &&
      onDiskLines[i] == generatedLines[i]) {
    i++;
  }
  buffer.writeln('  First difference at line ${i + 1}:');
  buffer.writeln(
    '    committed: ${i < onDiskLines.length ? onDiskLines[i] : '<end of file>'}',
  );
  buffer.writeln(
    '    generated: ${i < generatedLines.length ? generatedLines[i] : '<end of file>'}',
  );

  final onlyCommitted = onDiskLines.toSet().difference(generatedLines.toSet())
    ..removeWhere((l) => l.trim().isEmpty);
  final onlyGenerated = generatedLines.toSet().difference(onDiskLines.toSet())
    ..removeWhere((l) => l.trim().isEmpty);
  _writeSample(buffer, 'Only in the committed file', onlyCommitted);
  _writeSample(buffer, 'Only in the freshly generated file', onlyGenerated);
  return buffer.toString();
}

void _writeSample(StringBuffer buffer, String label, Set<String> lines) {
  if (lines.isEmpty) return;
  final sorted = lines.toList()..sort();
  final shown = sorted.take(_driftSamples).map((l) => l.trim()).join(' | ');
  final suffix = sorted.length > _driftSamples
      ? ' (showing $_driftSamples of ${sorted.length})'
      : '';
  buffer.writeln('  $label$suffix: $shown');
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
