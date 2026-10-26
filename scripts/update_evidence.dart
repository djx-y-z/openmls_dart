#!/usr/bin/env dart

/// Write down what an upstream update changed, for whoever reads it next.
///
/// One directory: the release notes, the upstream range (its commits, its
/// files, and the patches to the crates this package builds), how the
/// lockfile moved, and the range of every git dependency from another
/// repository that moved with it — the one range nothing else fetches. The
/// CHANGELOG script gathers the same facts through the same code
/// (`gatherUpdateEvidence`) before it asks a model; this writes them down for
/// the build repair, which reads them from `.agent-scratch/evidence/`, and for
/// a person reviewing the update, who gets them as a workflow artifact.
///
/// Evidence, not a gate: what cannot be had is named in the index and left
/// out, and the exit code is 0. It is 2 only when no range can be named or
/// the directory cannot be written.
///
/// Usage:
///   fvm dart scripts/update_evidence.dart --out [dir] [options]
///
/// Options:
///   - `--out [dir]`       Where to write (required)
///   - `--version [pin]`   The pin updated to; by default `upstream_version`
///                         in `.copier-answers.yml`
///   - `--from [pin]`      The pin updated from; by default the same answer
///                         as the base has it
///   - `--base [ref]`      The git ref the update started from (default HEAD)
///   - `--base-dir [dir]`  Instead, a directory holding the base's
///                         `rust/Cargo.lock`, `rust/Cargo.toml` and
///                         `.copier-answers.yml`
///   - `--help, -h`        Show this help
library;

import 'dart:convert';
import 'dart:io';

import 'src/common.dart';
import 'src/update_changelog.dart';
import 'src/upstream_source.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }
  String? option(String name) {
    final at = args.indexOf(name);
    return at != -1 && at + 1 < args.length ? args[at + 1] : null;
  }

  final outPath = option('--out');
  if (outPath == null) {
    logError('--out is required');
    _printUsage();
    exit(2);
  }
  final packageDir = getPackageDir();
  final baseDir = option('--base-dir');
  final baseRef = option('--base') ?? 'HEAD';
  final readBase = baseDir == null
      ? gitBaseReader(packageDir, baseRef)
      : dirBaseReader(Directory(baseDir));
  final base = baseDir == null
      ? '`$baseRef`'
      : 'the files it started from, copied to `$baseDir`';

  final answers = File('${packageDir.path}/.copier-answers.yml');
  final version =
      option('--version') ??
      (answers.existsSync()
          ? upstreamVersionIn(answers.readAsStringSync())
          : null);
  if (version == null) {
    logError(
      'No upstream version: pass --version, or run where .copier-answers.yml '
      'records upstream_version.',
    );
    exit(2);
  }
  final answersBefore = await readBase('.copier-answers.yml');
  var fromVersion =
      option('--from') ??
      (answersBefore == null ? null : upstreamVersionIn(answersBefore));
  if (fromVersion == version) fromVersion = null;

  final UpdateEvidence evidence;
  try {
    evidence = await gatherUpdateEvidence(
      version: version,
      fromVersion: fromVersion,
      readBase: readBase,
    );
  } on Object catch (e) {
    logError('Could not gather the evidence: $e');
    exit(2);
  }

  final out = Directory(outPath);
  final files = <String, String>{};
  final missing = <String>[];
  void write(String name, String text, String what) {
    final file = File('${out.path}/$name');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text.endsWith('\n') ? text : '$text\n');
    files[name] = what;
  }

  try {
    out.createSync(recursive: true);
    write(
      'release-notes.md',
      '# Release notes of $version\n\n${evidence.releaseNotes}',
      'the release\'s own notes',
    );

    final compare = evidence.compareJson;
    if (compare == null) {
      missing.add(
        fromVersion == null
            ? 'The upstream range: there is no earlier pin to compare from.'
            : 'The upstream range: the compare could not be fetched.',
      );
    } else {
      write(
        'upstream-commits.md',
        '# Commits in the range\n\n${evidence.upstreamCommits}',
        'the commits in the range, merges left out',
      );
      write(
        'upstream-files.md',
        '# Files the range touches\n\n${evidence.upstreamFiles}',
        'every file the range touches, those in the crates this package '
            'builds first',
      );
      if (evidence.upstreamPatches.isEmpty) {
        missing.add(
          evidence.crates.isEmpty
              ? 'Patches: the crates this package builds are unknown.'
              : 'Patches: the range changes no file in the crates this '
                    'package builds.',
        );
      } else {
        write(
          'upstream-patches.md',
          '# What changed in the crates this package builds\n\n'
              '${evidence.upstreamPatches}',
          'the patches to the crates this package builds, line by line',
        );
      }
      write(
        'upstream-compare.json',
        const JsonEncoder.withIndent('  ').convert(compare),
        'the compare payload as the API returned it',
      );
    }

    final lockBefore = evidence.lock.before;
    final lockAfter = evidence.lock.after;
    if (lockBefore == null || lockAfter == null) {
      missing.add(
        'The lockfile diff: `rust/Cargo.lock` could not be read before the '
        'update and after it, so the other git dependencies are unknown too.',
      );
    } else {
      write(
        'lockfile.md',
        '# How the lockfile moved\n\n'
            '${evidence.lock.prompt.isEmpty ? 'Nothing moved.' : evidence.lock.prompt}\n\n'
            '## As the CHANGELOG entry states it\n\n'
            '${evidence.lock.paragraph.isEmpty ? '(no paragraph)' : evidence.lock.paragraph}',
        'how the resolved graph moved, and the sentence the entry gains',
      );
      final deps = otherGitDepRangesFrom(
        lockBefore,
        lockAfter,
        upstreamRepo: upstreamSource.repo,
      );
      for (final range in deps.ranges) {
        final name = range.crates.first;
        try {
          final json =
              jsonDecode(
                    await upstreamHttp.getJson(
                      Uri.parse(
                        'https://api.github.com/repos/${range.repo}/compare/'
                        '${range.was}...${range.now}?per_page=250',
                      ),
                    ),
                  )
                  as Map<String, dynamic>;
          write(
            'other-git-deps/$name.md',
            gitDepRangeEvidenceFrom(range, json),
            'the range of `$name`, a git dependency from `${range.repo}` that '
                'moved ${range.wasVersion} → ${range.nowVersion}',
          );
        } on Object catch (e) {
          missing.add('The range of `$name` (`${range.repo}`): $e');
        }
      }
      for (final reason in deps.unranged) {
        missing.add('$reason.');
      }
    }

    write(
      'README.md',
      evidenceIndexFrom(
        version: version,
        fromVersion: fromVersion,
        base: base,
        from: evidence.from,
        to: evidence.to,
        files: files,
        missing: missing,
      ),
      'this index',
    );
  } on FileSystemException catch (e) {
    logError('Could not write $outPath: $e');
    exit(2);
  }
  logSuccess(
    'Wrote ${files.length} file(s) to $outPath'
    '${missing.isEmpty ? '' : '; ${missing.length} piece(s) missing, named '
              'in its README.md'}.',
  );
}

void _printUsage() {
  print('''
Write down what an upstream update changed

Usage:
  fvm dart scripts/update_evidence.dart --out <dir> [options]

Options:
  --out <dir>        Where to write (required)
  --version <pin>    The pin updated to; by default upstream_version in
                     .copier-answers.yml
  --from <pin>       The pin updated from; by default the same answer as the
                     base has it
  --base <ref>       The git ref the update started from (default HEAD)
  --base-dir <dir>   Instead, a directory holding the base's rust/Cargo.lock,
                     rust/Cargo.toml and .copier-answers.yml
  --help, -h         Show this help

Writes release-notes.md, upstream-commits.md, upstream-files.md,
upstream-patches.md, upstream-compare.json, lockfile.md,
other-git-deps/<crate>.md and an index, README.md, that names what is missing.
''');
}
