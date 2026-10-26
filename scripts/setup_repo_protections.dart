#!/usr/bin/env dart

/// Apply the repository rulesets, repo settings and the two release
/// environments to the GitHub repo.
///
/// The `.github/rulesets/*.json` files are the committed source of truth. This
/// script applies each to GitHub via `gh api`, idempotent by ruleset name
/// (existing rulesets are skipped unless `--update`), turns on automatic
/// head-branch deletion, and configures the environments the release jobs run
/// in, `native-build` (the native binaries) and `pub.dev` (the package): you as
/// the required reviewer, no admin bypass, and entry only from the release tags
/// their workflows are pushed by. What it sends is in `src/repo_protections.dart`.
///
/// Run it AFTER the GitHub repo exists (i.e. after `gh repo create` / first
/// push) — rulesets and environments live on GitHub, not in a local repo.
///
/// Usage:
///   make setup-repo-protections
///   make setup-repo-protections ARGS="--dry-run"         # show, change nothing
///   make setup-repo-protections ARGS="--update"          # overwrite existing
///   make setup-repo-protections ARGS="--no-environment"  # rulesets only
///   make setup-repo-protections ARGS="--yes"             # no confirmation
library;

import 'dart:convert';
import 'dart:io';

import 'src/common.dart';
import 'src/release_common.dart';
import 'src/repo_protections.dart';

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }
  final update = args.contains('--update');
  final skipEnv = args.contains('--no-environment');
  final assumeYes = args.contains('--yes') || args.contains('-y');
  final dryRun = args.contains('--dry-run');

  try {
    await _requireGh();
    final slug = await _repoSlug();
    final environments = skipEnv
        ? const <ReleaseEnvironment>[]
        : releaseEnvironments(getCrateName());

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
    if (skipEnv) {
      logInfo('Environments: skipped (--no-environment)');
    }
    for (final env in environments) {
      logInfo(
        'Environment: ${env.name} — only ${env.tagPattern} tags may enter, '
        'you review, no admin bypass',
      );
    }
    if (dryRun) {
      logInfo('Dry run: reading only, nothing is changed.');
    } else if (!assumeYes && !confirm('Apply to $slug?')) {
      logWarn('Aborted.');
      return;
    }

    final existing = await _existingRulesetIds(slug);
    for (final file in files) {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final name = data['name'] as String;
      final id = existing[name];
      if (id != null) {
        if (!update) {
          logInfo(
            'Ruleset "$name" already exists — skipping (--update to overwrite).',
          );
        } else if (dryRun) {
          logInfo(
            'Would update ruleset "$name" (PUT repos/$slug/rulesets/$id).',
          );
        } else {
          logStep('Updating ruleset "$name"...');
          await _ghInput([
            'api',
            '--method',
            'PUT',
            'repos/$slug/rulesets/$id',
          ], file);
          logSuccess('Updated "$name".');
        }
      } else if (dryRun) {
        logInfo('Would create ruleset "$name" (POST repos/$slug/rulesets).');
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

    if (dryRun) {
      logInfo('Would set delete_branch_on_merge=true (PATCH repos/$slug).');
    } else {
      await _setupRepoSettings(slug);
    }

    if (environments.isNotEmpty) {
      await _setupEnvironments(slug, environments, dryRun: dryRun);
    }

    print('');
    if (dryRun) {
      logSuccess('Dry run done: nothing was changed.');
      return;
    }
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

/// Runs `gh <args>` with [body] as the JSON request body.
Future<ProcessResult> _ghWithBody(List<String> args, Object body) async {
  final tmp = Directory.systemTemp.createTempSync('repo-protections-');
  try {
    final file = File('${tmp.path}/body.json')
      ..writeAsStringSync(jsonEncode(body));
    return await Process.run('gh', [...args, '--input', file.path]);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

/// `GET <path>`: the decoded JSON, or null when GitHub answers 404. Any other
/// failure throws.
Future<Object?> _apiGet(String path) async {
  final result = await Process.run('gh', ['api', path]);
  if (result.exitCode == 0) return jsonDecode(result.stdout as String);
  final stderr = (result.stderr as String).trim();
  if (stderr.contains('HTTP 404')) return null;
  throw Exception('gh api $path failed: $stderr');
}

/// An environment's deployment policies, or null when it has none to list:
/// GitHub answers 404 while the environment is missing or lets every branch in.
Future<List<Map<String, Object?>>?> _policies(String environmentPath) async {
  final json = await _apiGet(
    '$environmentPath/deployment-branch-policies?per_page=100',
  );
  if (json == null) return null;
  return [
    for (final p in (json as Map)['branch_policies'] as List? ?? const [])
      (p as Map).cast<String, Object?>(),
  ];
}

/// The authenticated user's numeric id, which is what a reviewer entry takes.
Future<int?> _currentUserId() async {
  final user = await Process.run('gh', ['api', 'user', '--jq', '.id']);
  return user.exitCode == 0
      ? int.tryParse((user.stdout as String).trim())
      : null;
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

/// Configures each release environment with [environmentBody], adds the tag
/// policy [planTagPolicy] calls for, then reads the environment back and
/// reports whatever still differs. Warns (does not fail the run) when GitHub
/// refuses: environment protections in a private repository depend on its
/// plan. With [dryRun] it only reads, and prints what it would send.
Future<void> _setupEnvironments(
  String slug,
  List<ReleaseEnvironment> environments, {
  required bool dryRun,
}) async {
  final uid = await _currentUserId();
  if (uid == null) {
    logWarn(
      'Could not resolve your GitHub user id — configure the environments '
      'manually at Settings → Environments.',
    );
    return;
  }
  for (final env in environments) {
    final path = 'repos/$slug/environments/${env.name}';
    final body = environmentBody(uid);
    final policyBody = tagPolicyBody(env.tagPattern);
    print('');
    logStep(
      'Environment `${env.name}` (${env.workflow}, job `${env.job}`): '
      'only `${env.tagPattern}` tags may enter.',
    );

    if (dryRun) {
      final live = await _apiGet(path);
      final policies = live == null ? null : await _policies(path);
      if (live == null) {
        logInfo('It does not exist yet.');
      } else {
        final changes = environmentMismatches(
          (live as Map).cast<String, Object?>(),
          policies ?? const [],
          reviewerId: uid,
          tagPattern: env.tagPattern,
        );
        if (changes.isEmpty) {
          logInfo('It already matches; the requests below change nothing.');
        }
        for (final change in changes) {
          logInfo('Now: $change');
        }
      }
      logInfo('Would send: PUT $path');
      print('    ${jsonEncode(body)}');
      final plan = planTagPolicy(policies ?? const [], env.tagPattern);
      if (plan.create) {
        logInfo('Would send: POST $path/deployment-branch-policies');
        print('    ${jsonEncode(policyBody)}');
      }
      for (final extra in plan.extra) {
        logWarn(
          'Left as it is: a policy that also lets in '
          '${extra['type'] ?? 'branch'} "${extra['name']}" (id ${extra['id']}).',
        );
      }
      continue;
    }

    final put = await _ghWithBody(['api', '--method', 'PUT', path], body);
    if (put.exitCode != 0) {
      logWarn(
        'GitHub refused the `${env.name}` environment '
        '(${(put.stderr as String).trim()}). Environment protections in a '
        'private repository depend on its plan; set them at '
        'Settings → Environments → ${env.name}.',
      );
      continue;
    }
    final plan = planTagPolicy(
      await _policies(path) ?? const [],
      env.tagPattern,
    );
    if (plan.create) {
      final post = await _ghWithBody([
        'api',
        '--method',
        'POST',
        '$path/deployment-branch-policies',
      ], policyBody);
      if (post.exitCode != 0) {
        logWarn(
          'Could not add the ${env.tagPattern} tag policy to `${env.name}` '
          '(${(post.stderr as String).trim()}).',
        );
      }
    }

    // Read back what GitHub now holds, rather than trusting the answers.
    final live = await _apiGet(path);
    final problems = live == null
        ? ['the environment could not be read back']
        : environmentMismatches(
            (live as Map).cast<String, Object?>(),
            await _policies(path) ?? const [],
            reviewerId: uid,
            tagPattern: env.tagPattern,
          );
    if (problems.isEmpty) {
      logSuccess(
        '`${env.name}`: only ${env.tagPattern} tags may enter, and a run waits '
        'for your approval, an Admin\'s too.',
      );
    }
    for (final problem in problems) {
      logWarn('`${env.name}`: $problem');
    }
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

void _printUsage() {
  print('''
Apply repository rulesets, repo settings and the two release environments
(native-build, pub.dev) to the GitHub repo.

The .github/rulesets/*.json files are the committed source of truth. Run this
AFTER the GitHub repo exists (rulesets/environments live on GitHub).

Usage:
  make setup-repo-protections [ARGS="..."]

Options:
  --dry-run          Read only: show what would change and the requests it
                     would send, and change nothing
  --update           Overwrite rulesets that already exist (PUT), not just skip
  --no-environment   Apply rulesets only; skip the release environments
  --yes, -y          Skip the confirmation prompt
  --help, -h         Show this help

Notes:
  - Requires the `gh` CLI authenticated as a repo admin.
  - Idempotent by ruleset name: existing rulesets are skipped unless --update.
  - Always sets delete_branch_on_merge=true (merged PRs delete their branch);
    --no-environment does not skip it, and re-running is harmless.
  - Each environment gets you as its one required reviewer, no admin bypass and
    a single deployment policy for its release tags: native-build for
    <crate>-* (rust/Cargo.toml's name), pub.dev for v*. Re-running converges on
    the same settings; a policy someone added is reported and left in place.
  - Optional/project-specific fields (e.g. a bypass actor for an automation
    GitHub App in signing-commit.json) are edited directly in the JSON files.
    Find an App's Integration id via:
      gh api repos/<owner>/<repo>/installations --jq '.installations[].app_id'
''');
}
