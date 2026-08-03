// Shared helpers for the two-stage release scripts (`release_frb.dart` for the
// native crate — stage 1 — and `release.dart` for the Dart package — stage 2).
//
// These wrap git and terminal interaction. `runInherit` starts subprocesses
// with `ProcessStartMode.inheritStdio` so interactive prompts — notably the
// commit/tag signing passphrase — work during a release.
library;

import 'dart:io';

import 'common.dart';

/// Ensures the current directory is inside a git work tree.
Future<void> ensureGitRepo() async {
  final result = await Process.run('git', [
    'rev-parse',
    '--is-inside-work-tree',
  ]);
  if (result.exitCode != 0 || (result.stdout as String).trim() != 'true') {
    throw Exception('Not inside a git repository.');
  }
}

/// Runs a read-only git command and returns trimmed stdout, throwing on error.
///
/// For scalar answers — a sha, a branch name, a count. **Not** for
/// `status --porcelain`; use [gitStatus], which keeps the leading whitespace
/// that command's format depends on.
Future<String> git(List<String> args) async {
  final result = await Process.run('git', args);
  if (result.exitCode != 0) {
    throw Exception(
      'git ${args.join(' ')} failed: ${(result.stderr as String).trim()}',
    );
  }
  return (result.stdout as String).trim();
}

/// `git status --porcelain`, with leading whitespace preserved.
///
/// The two status columns are positional, so an unstaged modification is
/// `' M path'`. Reading this through [git] trims the whole output and eats the
/// leading space of the *first* line, shifting that path by one character so it
/// matches nothing — which made [onlyTheseFilesDirty] return false for the
/// entire status and silently downgraded the `git restore` hint to the generic
/// "working tree is not clean".
///
/// That hit exactly the case the hint exists for: a release edits its files
/// without staging them, so after an interrupted run the first line is always
/// an unstaged modification. Verified by calling [onlyTheseFilesDirty] with a
/// real two-file status both raw (true) and as [git] returned it (false).
Future<String> gitStatus() async {
  final result = await Process.run('git', ['status', '--porcelain']);
  if (result.exitCode != 0) {
    throw Exception(
      'git status --porcelain failed: ${(result.stderr as String).trim()}',
    );
  }
  // Only trailing newlines: everything else is payload.
  return (result.stdout as String).replaceAll(RegExp(r'\n+$'), '');
}

/// Runs a command with inherited stdio (so interactive prompts — e.g. the
/// signing passphrase — work), throwing on a non-zero exit.
///
/// Always fails loud: a non-zero exit throws even when [failMessage] is null
/// (with a generic message), so a failed step — e.g. `git add` hitting a stale
/// `.git/index.lock` — cannot silently fall through into the next command.
Future<void> runInherit(
  String command,
  List<String> args, {
  String? failMessage,
}) async {
  final process = await Process.start(
    command,
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) {
    final message = failMessage ?? '`$command ${args.join(' ')}` failed';
    throw Exception('$message (exit $code)');
  }
}

/// Runs a command with inherited stdio like [runInherit], but re-runs it on
/// failure instead of throwing on the first one. [what] names the step in the
/// messages (e.g. `'git commit'`).
///
/// This exists for the signing steps. Git signs a commit or a tag by shelling
/// out to `ssh-keygen -Y sign` / `gpg`, and both give up after a *single*
/// mistyped passphrase — they do not re-prompt. Without a retry, one typo
/// aborts the release wherever it happened, and the worst position is between
/// the commit and the tag: the version bump is committed, no tag exists, and
/// the release cannot simply be re-run over that state.
///
/// The retry is automatic and unprompted — the failure is reported and the step
/// runs again, so the passphrase prompt simply comes back, the way `ssh` and
/// `sudo` behave. **Ctrl-C is the interactive way out**, so it must stay one:
/// nothing here may install a SIGINT handler without exiting from it.
///
/// The loop is uncapped on purpose — a cap would reinstate the very failure
/// this prevents, the run that dies on the last allowed typo — so the two
/// things keeping it bounded matter:
///
///  * **Non-interactive stdin throws immediately** (see [stdinIsTerminal]).
///    Nobody is there to retype anything and nobody can interrupt it, so a
///    step that fails structurally (a broken key path, a failing pre-commit
///    hook in CI) would otherwise spin forever.
///  * **From the third consecutive failure the loop paces itself** and says so.
///    A retry after a typo is immediate, so the common case is not slowed; a
///    step failing in milliseconds for a reason no passphrase will fix cannot
///    scroll the terminal faster than it can be read and interrupted.
///
/// [alreadyDone] is consulted after a failure: a step whose effect is already
/// in place — a commit that landed despite a non-zero exit — reports success
/// instead of being attempted a second time. [beforeRetry] runs before each
/// retry, for a step whose precondition has to be re-established first
/// (re-staging files that a pre-commit hook rewrote).
Future<void> runInheritRetry(
  String command,
  List<String> args, {
  required String what,
  String? failMessage,
  Future<bool> Function()? alreadyDone,
  Future<void> Function()? beforeRetry,
}) async {
  for (var attempt = 1; ; attempt++) {
    final process = await Process.start(
      command,
      args,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code == 0) return;

    if (alreadyDone != null && await alreadyDone()) {
      logWarn('$what exited $code, but its result is already in place.');
      return;
    }

    print('');
    logError('$what failed (exit $code).');

    if (!stdinIsTerminal()) {
      final message = failMessage ?? '`$command ${args.join(' ')}` failed';
      throw Exception('$message (exit $code)');
    }

    if (attempt >= 3) {
      logWarn(
        'Attempt $attempt failed. Retrying in 2s — press Ctrl-C to abort. '
        'If a passphrase is not what is failing, the message above says what '
        'is.',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    } else {
      logInfo(
        'A mistyped signing passphrase is the usual cause — signing tools do '
        'not re-prompt on their own. Retrying; enter it again (Ctrl-C to '
        'abort).',
      );
    }
    if (beforeRetry != null) await beforeRetry();
  }
}

/// Whether stdin is a real terminal — i.e. whether a human can answer a prompt,
/// retype a passphrase, or interrupt a loop.
///
/// `stdin.hasTerminal` does NOT answer this: it reports `StdioType.terminal`
/// for any character device, so a run redirected from `/dev/null` looks
/// interactive to it (verified on macOS with Dart 3.10). Reading a termios
/// attribute asks the real question — it throws on anything that is not a tty,
/// and only a pty answers it.
bool stdinIsTerminal() {
  try {
    stdin.echoMode;
    return true;
  } catch (_) {
    return false;
  }
}

/// Prompts a yes/no question on the terminal; defaults to no.
///
/// Returns false without prompting when stdin is not a terminal, and false on
/// EOF, so a non-interactive run neither blocks nor treats an empty stdin as
/// consent.
bool confirm(String prompt) {
  if (!stdinIsTerminal()) return false;
  stdout.write('$prompt [y/N] ');
  final line = stdin.readLineSync();
  if (line == null) return false;
  final answer = line.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

/// Whether every path reported dirty by `git status --porcelain` is one of
/// [files] — i.e. whether the only thing standing in the way is a release's own
/// half-applied edits, which the caller can then say how to discard.
///
/// Conservative by construction: an empty status (nothing dirty), an untracked
/// path (`??`, which `git restore` would not help with), or a rename (whose
/// porcelain payload is `old -> new` and matches no plain path) all return
/// false, so the caller falls back to its generic message rather than
/// suggesting a command that would not work — or, worse, one that would discard
/// something else.
bool onlyTheseFilesDirty(String porcelainStatus, List<String> files) {
  final lines = porcelainStatus
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) return false;
  return lines.every(
    (l) =>
        l.length > 3 && !l.startsWith('??') && files.contains(l.substring(3)),
  );
}

/// Whether a previous run already created this release's version-bump commit,
/// so the current run should resume at the tag/push step rather than bump and
/// commit again.
///
/// A release that dies between its commit and its tag — a mistyped passphrase
/// with the retry declined, a Ctrl-C, a closed terminal — leaves a state that
/// blocks a plain re-run: the version file already reads [requestedVersion], so
/// the "must be greater than the current version" precondition rejects it, and
/// the only ways out are reverting the commit or tagging and pushing by hand.
///
/// This is the one predicate here whose false positive is dangerous: it would
/// tag and push a commit that is not the release commit. So it requires all of:
///
///  * [treeClean] — nothing half-applied on top of the commit;
///  * [currentVersion] already equal to [requestedVersion] — the bump landed;
///  * [headSubject] equal to [expectedSubject] — `HEAD` is that commit and not
///    merely some commit made afterwards.
///
/// Callers must pass the *same* expression for [expectedSubject] that they pass
/// to `git commit -m`, so the two cannot drift apart and silently disable
/// resuming.
bool isResumableRelease({
  required String requestedVersion,
  required String currentVersion,
  required String headSubject,
  required String expectedSubject,
  required bool treeClean,
}) =>
    treeClean &&
    currentVersion == requestedVersion &&
    headSubject == expectedSubject;

/// Returns true if [a] is a strictly greater X.Y.Z version than [b].
///
/// If either side can't be parsed as X.Y.Z, logs a warning and returns true so
/// a release is not blocked on a parse quirk.
bool isNewerVersion(String a, String b) {
  List<int>? parse(String v) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(v.trim());
    if (m == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
  }

  final pa = parse(a);
  final pb = parse(b);
  if (pa == null || pb == null) {
    logWarn(
      'Could not compare versions "$a" and "$b"; skipping the '
      'greater-than check.',
    );
    return true;
  }
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] > pb[i];
  }
  return false;
}
