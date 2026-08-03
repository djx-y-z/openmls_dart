#!/usr/bin/env dart

/// Apply the repository rulesets, repo settings and the `native-build`
/// environment to the GitHub repo.
///
/// The `.github/rulesets/*.json` files are the committed source of truth. This
/// script applies each to GitHub via `gh api`, idempotent by ruleset name
/// (existing rulesets are skipped unless `--update`), turns on automatic
/// head-branch deletion, and configures the `native-build` environment with you
/// as a required reviewer.
///
/// Run it AFTER the GitHub repo exists (i.e. after `gh repo create` / first
/// push) — rulesets and environments live on GitHub, not in a local repo.
///
/// Usage:
///   make setup-repo-protections
///   make setup-repo-protections ARGS="--update"          # overwrite existing
///   make setup-repo-protections ARGS="--no-environment"  # rulesets only
///   make setup-repo-protections ARGS="--yes"             # no confirmation
library;

import 'dart:convert';
import 'dart:io';

import 'src/common.dart';
import 'src/release_common.dart';

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }
  final update = args.contains('--update');
  final skipEnv = args.contains('--no-environment');
  final assumeYes = args.contains('--yes') || args.contains('-y');

  try {
    await _requireGh();
    final slug = await _repoSlug();

    final dir = Directory('${getPackageDir().path}/.github/rulesets');
    if (!dir.existsSync()) {
      throw Exception('No .github/rulesets/ directory found.');
    }
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      throw Exception('No ruleset .json files in .github/rulesets/.');
    }

    print('');
    logInfo('Repository:  $slug');
    logInfo('Rulesets:    ${files.map((f) => _basename(f.path)).join(', ')}');
    logInfo('Settings:    delete_branch_on_merge = true');
    logInfo(
      'Environment: ${skipEnv ? 'native-build (skipped)' : 'native-build (reviewer: you)'}',
    );
    if (!assumeYes && !confirm('Apply to $slug?')) {
      logWarn('Aborted.');
      return;
    }

    final existing = await _existingRulesetIds(slug);
    for (final file in files) {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final name = data['name'] as String;
      final id = existing[name];
      if (id != null) {
        if (update) {
          logStep('Updating ruleset "$name"...');
          await _ghInput([
            'api',
            '--method',
            'PUT',
            'repos/$slug/rulesets/$id',
          ], file);
          logSuccess('Updated "$name".');
        } else {
          logInfo(
            'Ruleset "$name" already exists — skipping (--update to overwrite).',
          );
        }
      } else {
        logStep('Creating ruleset "$name"...');
        await _ghInput([
          'api',
          '--method',
          'POST',
          'repos/$slug/rulesets',
        ], file);
        logSuccess('Created "$name".');
      }
    }

    await _setupRepoSettings(slug);

    if (!skipEnv) {
      await _setupNativeBuildEnvironment(slug);
    }

    print('');
    logSuccess('Repository protections applied.');
    logInfo("Verify: gh api repos/$slug/rulesets --jq '.[] | .name'");
  } catch (e) {
    print('');
    logError('$e');
    exit(1);
  }
}

/// Returns `owner/repo` parsed from `git remote get-url origin`.
Future<String> _repoSlug() async {
  final result = await Process.run('git', ['remote', 'get-url', 'origin']);
  if (result.exitCode != 0) {
    throw Exception(
      'Could not read the origin remote — is this a GitHub repo with a remote?',
    );
  }
  var url = (result.stdout as String).trim();
  if (url.endsWith('.git')) url = url.substring(0, url.length - 4);
  // https://github.com/OWNER/REPO  or  git@github.com:OWNER/REPO
  final match = RegExp(r'[:/]([^/:]+/[^/:]+)$').firstMatch(url);
  if (match == null) {
    throw Exception('Could not parse owner/repo from remote "$url".');
  }
  return match.group(1)!;
}

/// Verifies `gh` is installed and authenticated.
Future<void> _requireGh() async {
  if (!await commandExists('gh')) {
    throw Exception(
      'The `gh` CLI is required (https://cli.github.com). '
      'Alternatively, apply each .github/rulesets/*.json manually with '
      '`gh api --method POST repos/<owner>/<repo>/rulesets --input <file>`.',
    );
  }
  final auth = await Process.run('gh', ['auth', 'status']);
  if (auth.exitCode != 0) {
    throw Exception('`gh` is not authenticated. Run: gh auth login');
  }
}

/// Maps existing ruleset name -> id for the repo.
Future<Map<String, int>> _existingRulesetIds(String slug) async {
  final result = await Process.run('gh', [
    'api',
    'repos/$slug/rulesets',
    '--paginate',
  ]);
  if (result.exitCode != 0) {
    throw Exception(
      'Failed to list rulesets (need admin access): '
      '${(result.stderr as String).trim()}',
    );
  }
  final list = jsonDecode(result.stdout as String) as List<Object?>;
  return {
    for (final entry in list.cast<Map<String, dynamic>>())
      entry['name'] as String: entry['id'] as int,
  };
}

/// Runs `gh <args> --input <file>`, throwing with gh's stderr on failure.
Future<void> _ghInput(List<String> args, File input) async {
  final result = await Process.run('gh', [...args, '--input', input.path]);
  if (result.exitCode != 0) {
    throw Exception(
      'gh ${args.join(' ')} failed: ${(result.stderr as String).trim()}',
    );
  }
}

/// Turns on "Automatically delete head branches" so a merged pull request does
/// not leave its branch behind. Warns (does not fail the run) if it can't.
///
/// The automation branches are what make this worth setting: the dependency and
/// template update workflows open one branch per upstream version, and without
/// this every merged one stays forever.
///
/// Caveat: GitHub performs the deletion as whoever merged the pull request, and
/// a `deletion` ruleset covering the branch restricts that to the ruleset's
/// bypass actors — so for a merger without that bypass this may quietly do
/// nothing. It cannot make things worse; the branch simply stays, as it does
/// with the setting off.
Future<void> _setupRepoSettings(String slug) async {
  logStep('Enabling automatic head-branch deletion on merge...');
  final result = await Process.run('gh', [
    'api',
    '--method',
    'PATCH',
    'repos/$slug',
    '-F',
    'delete_branch_on_merge=true',
    '--silent',
  ]);
  if (result.exitCode != 0) {
    logWarn(
      'Could not set delete_branch_on_merge '
      '(${(result.stderr as String).trim()}). Enable it manually at '
      'Settings → General → "Automatically delete head branches".',
    );
  } else {
    logSuccess('Merged pull requests now delete their head branch.');
  }
}

/// Creates/updates the `native-build` environment with the current user as a
/// required reviewer. Warns (does not fail the run) if it can't.
Future<void> _setupNativeBuildEnvironment(String slug) async {
  logStep(
    'Configuring the `native-build` environment (required reviewer: you)...',
  );
  final user = await Process.run('gh', ['api', 'user', '--jq', '.id']);
  final uid = user.exitCode == 0
      ? int.tryParse((user.stdout as String).trim())
      : null;
  if (uid == null) {
    logWarn(
      'Could not resolve your GitHub user id — add required reviewers manually '
      'at Settings → Environments → native-build.',
    );
    return;
  }
  final body = jsonEncode({
    'reviewers': [
      {'type': 'User', 'id': uid},
    ],
  });
  final tmp = File('${Directory.systemTemp.path}/native-build-env.json')
    ..writeAsStringSync(body);
  try {
    final result = await Process.run('gh', [
      'api',
      '--method',
      'PUT',
      'repos/$slug/environments/native-build',
      '--input',
      tmp.path,
    ]);
    if (result.exitCode != 0) {
      logWarn(
        'Could not configure the native-build environment '
        '(${(result.stderr as String).trim()}). Set required reviewers '
        'manually at Settings → Environments → native-build.',
      );
    } else {
      logSuccess(
        'native-build environment now requires your approval to publish.',
      );
    }
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

void _printUsage() {
  print('''
Apply repository rulesets, repo settings + the native-build environment to the
GitHub repo.

The .github/rulesets/*.json files are the committed source of truth. Run this
AFTER the GitHub repo exists (rulesets/environments live on GitHub).

Usage:
  make setup-repo-protections [ARGS="..."]

Options:
  --update           Overwrite rulesets that already exist (PUT), not just skip
  --no-environment   Apply rulesets only; skip the native-build environment
  --yes, -y          Skip the confirmation prompt
  --help, -h         Show this help

Notes:
  - Requires the `gh` CLI authenticated as a repo admin.
  - Idempotent by ruleset name: existing rulesets are skipped unless --update.
  - Always sets delete_branch_on_merge=true (merged PRs delete their branch);
    --no-environment does not skip it, and re-running is harmless.
  - Optional/project-specific fields (e.g. a bypass actor for an automation
    GitHub App in signing-commit.json) are edited directly in the JSON files.
    Find an App's Integration id via:
      gh api repos/<owner>/<repo>/installations --jq '.installations[].app_id'
''');
}
