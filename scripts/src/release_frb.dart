// Release a new `openmls_frb` native crate version.
//
// This is the first of the two release stages (see CLAUDE.md):
//   1. openmls_frb native crate — THIS script: bump rust/Cargo.toml, stamp
//      the CHANGELOG Highlights line, commit, tag `openmls_frb-<version>`,
//      and push. The tag triggers `build-openmls.yml`, which builds and
//      publishes the native binaries.
//   2. Dart package — later, `make release` / the release-package skill: bump
//      pubspec, finalize CHANGELOG, tag `vX.Y.Z` → publish.yml (the native
//      binary from stage 1 already exists for the build hook to download).
//
// The commit and the tag are signed via your git config. Because the git
// subprocesses inherit this terminal (stdio), you enter your signing passphrase
// interactively mid-run — no separate manual commit/tag step is needed.
library;

import 'dart:io';

import 'common.dart';
import 'release_common.dart';
import 'third_party_notices.dart';

/// Cut a `openmls_frb` release for crate [version] (plain `X.Y.Z`).
///
/// Bumps `rust/Cargo.toml`, stamps the CHANGELOG `[Unreleased]` Highlights line,
/// creates a signed commit + signed tag `openmls_frb-<version>`, and (unless
/// [push] is false) pushes `main` and the tag. Prompts for confirmation before
/// committing unless [assumeYes].
Future<void> releaseFrb({
  required String version,
  bool push = true,
  bool assumeYes = false,
}) async {
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    throw Exception('Version must be plain X.Y.Z (got "$version").');
  }

  final packageDir = getPackageDir();
  final tag = 'openmls_frb-$version';

  // ---- Preconditions -------------------------------------------------------
  await ensureGitRepo();

  final branch = await git(['rev-parse', '--abbrev-ref', 'HEAD']);
  if (branch != 'main') {
    throw Exception(
      'Not on main (on "$branch"). frb releases are cut from '
      'main; check it out and pull first.',
    );
  }

  if ((await git(['status', '--porcelain'])).isNotEmpty) {
    throw Exception(
      'Working tree is not clean. Commit or stash changes first.',
    );
  }

  // Every archive built from this tag embeds THIRD_PARTY_NOTICES.txt, and a
  // pushed release tag cannot be taken back. Checked here rather than trusting
  // the last CI run, which may predate a local dependency change.
  logStep('Verifying third-party notices match the dependency graph...');
  assertNoticesCurrent();

  final current = getCrateVersion();
  if (!isNewerVersion(version, current)) {
    throw Exception(
      'New version $version must be greater than the current '
      'crate version $current.',
    );
  }

  if ((await git(['tag', '--list', tag])).isNotEmpty) {
    throw Exception('Tag $tag already exists locally.');
  }

  logStep('Fetching origin...');
  // Fetch only origin/main (all the behind/ahead check below needs). Not tags:
  // the "tag already on origin?" check uses `git ls-remote` directly, so `--tags`
  // adds nothing — but one diverged tag in the namespace would abort the release.
  await git(['fetch', 'origin', 'main', '--no-tags', '--quiet']);
  if ((await git(['ls-remote', '--tags', 'origin', tag])).isNotEmpty) {
    throw Exception('Tag $tag already exists on origin.');
  }

  final behind = await git(['rev-list', '--count', 'HEAD..origin/main']);
  if (behind != '0') {
    throw Exception(
      'Local main is behind origin/main by $behind commit(s). '
      'Run: git pull --ff-only origin main',
    );
  }
  final ahead = await git(['rev-list', '--count', 'origin/main..HEAD']);
  if (ahead != '0') {
    logWarn(
      'Local main is ahead of origin/main by $ahead commit(s); these '
      'will be pushed together with the release commit.',
    );
  }

  // ---- Prepare files -------------------------------------------------------
  logStep('Bumping rust/Cargo.toml crate version: $current -> $version');
  _bumpCargoVersion(packageDir, version);

  // Keep rust/Cargo.lock's own crate stanza in sync. The pre-commit hook runs
  // `cargo check`, which rewrites this line whether we do or not — doing it here
  // first means the lock change is previewed, staged, and committed instead of
  // being silently left as a dirty, unstaged edit that blocks the stage-2
  // clean-tree preflight.
  logStep('Syncing rust/Cargo.lock crate version...');
  _bumpCargoLockVersion(packageDir, getCrateName(), version);

  logStep('Stamping openmls_frb highlight into CHANGELOG [Unreleased]...');
  _stampFrbHighlight(packageDir, version);

  logStep('Changes to be committed:');
  await runInherit('git', [
    '--no-pager',
    'diff',
    '--stat',
    'rust/Cargo.toml',
    'rust/Cargo.lock',
    'CHANGELOG.md',
  ]);

  // ---- Confirm -------------------------------------------------------------
  final action = push
      ? 'commit + tag $tag + PUSH (this triggers the native build)'
      : 'commit + tag $tag (no push)';
  if (!assumeYes && !confirm('Proceed to $action?')) {
    await git([
      'checkout',
      '--',
      'rust/Cargo.toml',
      'rust/Cargo.lock',
      'CHANGELOG.md',
    ]);
    logWarn(
      'Aborted. Reverted rust/Cargo.toml, rust/Cargo.lock and '
      'CHANGELOG.md.',
    );
    return;
  }

  // ---- Commit + tag (signed; may prompt for your passphrase) ---------------
  logStep('Committing (you may be prompted for your signing passphrase)...');
  await runInherit('git', [
    'add',
    'rust/Cargo.toml',
    'rust/Cargo.lock',
    'CHANGELOG.md',
  ]);
  await runInherit(
    'git',
    ['commit', '-m', 'chore(openmls_frb): release v$version'],
    failMessage:
        'git commit failed (pre-commit checks or signing). The version bump is '
        'still staged — fix the issue and re-run `git commit`/`git tag` '
        'manually, or discard it with `git restore --staged --worktree '
        'rust/Cargo.toml rust/Cargo.lock CHANGELOG.md` and re-run the release.',
  );

  logStep('Creating signed tag $tag...');
  await runInherit(
    'git',
    ['tag', '-s', tag, '-m', 'openmls_frb v$version'],
    failMessage:
        'git tag failed. The release commit was created; tag manually '
        'with: git tag -s $tag -m "openmls_frb v$version"',
  );

  // ---- Push ----------------------------------------------------------------
  if (!push) {
    logSuccess('Committed and tagged $tag locally (not pushed).');
    logInfo('When ready: git push origin main && git push origin $tag');
    return;
  }

  logStep('Pushing main and tag $tag...');
  await runInherit('git', [
    'push',
    'origin',
    'main',
  ], failMessage: 'git push origin main failed.');
  await runInherit(
    'git',
    ['push', 'origin', tag],
    failMessage: 'git push tag failed. Push it manually: git push origin $tag',
  );

  logSuccess(
    'Pushed. "Build openmls FRB Libraries" will build and publish '
    'openmls_frb-$version.',
  );
  logInfo('Watch it: gh run watch (or the Actions tab).');
  logInfo(
    'After the native build succeeds, cut the Dart package release '
    '(make release / release-package skill → tag vX.Y.Z).',
  );
}

/// Rewrites the `[package]` version in rust/Cargo.toml to [version].
void _bumpCargoVersion(Directory packageDir, String version) {
  final file = File('${packageDir.path}/rust/Cargo.toml');
  final content = file.readAsStringSync();
  final pattern = RegExp(
    r'^(version\s*=\s*")(\d+\.\d+\.\d+)(")',
    multiLine: true,
  );
  if (!pattern.hasMatch(content)) {
    throw Exception(
      'Could not find a plain X.Y.Z [package] version in '
      'rust/Cargo.toml.',
    );
  }
  file.writeAsStringSync(
    content.replaceFirstMapped(
      pattern,
      (m) => '${m.group(1)}$version${m.group(3)}',
    ),
  );
}

/// Rewrites the `[[package]]` version stanza named [crateName] in
/// rust/Cargo.lock to [version] (reads and writes rust/Cargo.lock). No-op if the
/// lock does not exist.
void _bumpCargoLockVersion(
  Directory packageDir,
  String crateName,
  String version,
) {
  final file = File('${packageDir.path}/rust/Cargo.lock');
  if (!file.existsSync()) return;
  file.writeAsStringSync(
    bumpCargoLockVersion(file.readAsStringSync(), crateName, version),
  );
}

/// Pure form of [_bumpCargoLockVersion]: returns [content] (a Cargo.lock) with
/// the `version` of the `[[package]]` stanza named [crateName] set to [version].
/// Cargo rewrites this line whenever a workspace member's own version changes,
/// so the release stages the lock alongside Cargo.toml. Exposed for testing.
String bumpCargoLockVersion(String content, String crateName, String version) {
  final pattern = RegExp(
    '(name\\s*=\\s*"${RegExp.escape(crateName)}"\\r?\\nversion\\s*=\\s*")'
    r'(\d+\.\d+\.\d+)'
    '(")',
  );
  if (!pattern.hasMatch(content)) {
    throw Exception(
      'Could not find the [[package]] stanza for "$crateName" in '
      'rust/Cargo.lock.',
    );
  }
  return content.replaceFirstMapped(
    pattern,
    (m) => '${m.group(1)}$version${m.group(3)}',
  );
}

/// Inserts or updates the `**openmls_frb vX.Y.Z**` Highlights line inside the
/// CHANGELOG `[Unreleased]` section (reads and writes CHANGELOG.md).
void _stampFrbHighlight(Directory packageDir, String version) {
  final file = File('${packageDir.path}/CHANGELOG.md');
  file.writeAsStringSync(stampFrbHighlight(file.readAsStringSync(), version));
}

/// Pure form of [_stampFrbHighlight]: returns [content] with the
/// `**openmls_frb vX.Y.Z**` Highlights line inserted or updated inside the
/// `[Unreleased]` section. Exposed for testing.
String stampFrbHighlight(String content, String version) {
  final lines = content.split('\n');
  final frbLine = '- **openmls_frb v$version** — Rust FFI bindings';
  final frbPattern = RegExp(r'^\s*-\s*\*\*openmls_frb v');

  int firstVersionHeading() {
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('## [') && !lines[i].contains('Unreleased')) {
        return i;
      }
    }
    return lines.length;
  }

  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('## [Unreleased]')) {
      start = i;
      break;
    }
  }

  if (start == -1) {
    // No [Unreleased] section yet — create a minimal one.
    lines.insertAll(firstVersionHeading(), [
      '## [Unreleased]',
      '',
      '### For Users',
      '',
      '#### ✨ Highlights',
      '',
      frbLine,
      '',
      '',
    ]);
    return lines.join('\n');
  }

  var end = lines.length;
  for (var i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith('## [')) {
      end = i;
      break;
    }
  }

  // Replace an existing frb highlight in the section.
  for (var i = start + 1; i < end; i++) {
    if (frbPattern.hasMatch(lines[i])) {
      lines[i] = frbLine;
      return lines.join('\n');
    }
  }

  // Find the Highlights subsection header within the section.
  var highlights = -1;
  for (var i = start + 1; i < end; i++) {
    if (lines[i].startsWith('####') && lines[i].contains('Highlights')) {
      highlights = i;
      break;
    }
  }

  if (highlights == -1) {
    // No Highlights subsection — add one under `### For Users`. If the section
    // has no `### For Users` audience heading yet (e.g. a bare `## [Unreleased]`
    // heading added by hand with no audience sections), create it too, so the
    // stamped Highlights block never ends up parentless (the CLAUDE.md changelog
    // contract requires every subsection to sit under an audience heading).
    var insertAt = start + 1;
    var hasForUsers = false;
    for (var i = start + 1; i < end; i++) {
      if (lines[i].startsWith('### For Users')) {
        insertAt = i + 1;
        hasForUsers = true;
        break;
      }
    }
    lines.insertAll(insertAt, [
      '',
      if (!hasForUsers) ...['### For Users', ''],
      '#### ✨ Highlights',
      '',
      frbLine,
    ]);
    return lines.join('\n');
  }

  // Append after the last existing bullet in the Highlights block.
  var blockEnd = end;
  for (var i = highlights + 1; i < end; i++) {
    final l = lines[i];
    if (l.startsWith('####') || l.startsWith('###') || l.startsWith('## [')) {
      blockEnd = i;
      break;
    }
  }
  var lastBullet = -1;
  for (var i = highlights + 1; i < blockEnd; i++) {
    if (lines[i].trimLeft().startsWith('- ')) lastBullet = i;
  }
  if (lastBullet != -1) {
    lines.insert(lastBullet + 1, frbLine);
  } else {
    lines.insert(highlights + 1, frbLine);
    lines.insert(highlights + 1, '');
  }
  return lines.join('\n');
}
