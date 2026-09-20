// Update CHANGELOG.md with AI-generated entry for a openmls dependency
// update.
//
// The release notes and the upstream commit list are handed to whichever model
// `AI_MODELS` puts first (see `ai_client.dart`), which writes an entry matching
// this project's house style.
//
// NOTE: This step does NOT touch the `openmls_frb` crate version. The crate
// version is bumped as a deliberate release step (`make release-frb`), which
// also stamps the `openmls_frb vX.Y.Z` Highlights line. The automatic update
// PR only records the openmls dependency change (openmls Highlight +
// Changed entry).
library;

import 'dart:convert';
import 'dart:io';

import 'ai_client.dart';
import 'common.dart';

/// Update CHANGELOG.md with a new openmls version entry.
///
/// What [updateChangelog] reports back to its caller.
///
/// Two facts, and both exist because only this run can observe them: which
/// model wrote the entry, and whether the section was left naming two upstream
/// versions.
class ChangelogUpdate {
  /// Creates a result from the two facts a caller needs.
  const ChangelogUpdate({required this.model, required this.highlightsStacked});

  /// The model that wrote the entry, so a caller can publish it.
  final AiModel model;

  /// Whether `[Unreleased]` was left naming two upstream versions.
  ///
  /// True when a REWRITTEN openmls Highlights line was
  /// standing and this run's line was therefore added beside it instead of
  /// superseding it — see [hasRewrittenNativeHighlight] for why a rewritten one
  /// is never replaced. The condition is legitimate; going unreported is not.
  final bool highlightsStacked;
}

/// The `key=value` block [ChangelogUpdate] contributes to a `--ci-output` file.
///
/// Separated from the write so the format is checkable without running the
/// update: this is a GitHub Actions output file, appended to by several
/// writers, so a missing trailing newline joins this block to the next one and
/// both keys are lost. Both keys are emitted on BOTH outcomes — a key that
/// appears only when true cannot be told apart from a script too old to emit
/// it, and the false case is the one a reader relies on to mean "checked, and
/// the section is fine".
String ciOutputsFor(ChangelogUpdate update) =>
    'ai_provider=${update.model}\n'
    'highlights_stacked=${update.highlightsStacked}\n';

/// Returns what the caller has to publish — see [ChangelogUpdate].
Future<ChangelogUpdate> updateChangelog({
  required String version,
  required List<ResolvedAiModel> models,
  String? fromVersion,
  String? codegenResult,
  bool ciMode = false,
}) async {
  final packageDir = getPackageDir();

  // Step 1: Fetch release notes from GitHub.
  logStep('Fetching release notes for $version...');
  final releaseNotes = await _fetchReleaseNotes(version);
  logInfo('Got ${releaseNotes.length} characters of release notes');

  // Step 2: Fetch the actual commit list between the two tags — release notes
  // alone are often terse, which produced incomplete changelog entries.
  var upstreamCommits = '';
  var upstreamFiles = '';
  if (fromVersion != null && fromVersion != version) {
    logStep('Fetching upstream compare $fromVersion...$version...');
    try {
      final compare = await _fetchUpstreamCompare(fromVersion, version);
      upstreamCommits = compare.commits;
      upstreamFiles = compare.files;
      logInfo('Got ${upstreamCommits.length} characters of commit history');
      logInfo('Got ${upstreamFiles.length} characters of changed-file list');
    } catch (e) {
      logWarning('Could not fetch upstream compare: $e');
    }
  }

  // Step 3: Read current CHANGELOG.
  logStep('Reading CHANGELOG.md...');
  final changelogFile = File('${packageDir.path}/CHANGELOG.md');
  final currentChangelog = changelogFile.readAsStringSync();

  // Step 4: Analyze with AI.
  logStep('Analyzing release notes with AI...');
  final entry = await _generateChangelogEntry(
    version: version,
    fromVersion: fromVersion,
    releaseNotes: releaseNotes,
    upstreamCommits: upstreamCommits,
    upstreamFiles: upstreamFiles,
    currentChangelog: currentChangelog,
    codegenResult: codegenResult,
    models: models,
  );

  final nativeHighlight = entry.highlight;
  final changed = entry.changed;
  logInfo('Generated openmls highlight: $nativeHighlight');
  logInfo('Generated changed entry');

  // Step 5: Update CHANGELOG.
  logStep('Updating CHANGELOG.md...');
  // The new Highlights line supersedes this script's own default from an
  // earlier bump, but never a rewritten one — so say when one is left standing.
  // Both then name a version, and the section would ship claiming two.
  final highlightsStacked = hasRewrittenNativeHighlight(currentChangelog);
  if (highlightsStacked) {
    logWarning(
      '[Unreleased] already carries a rewritten openmls Highlights line. '
      'It was kept, so the section now names two upstream versions — collapse '
      'them by hand before releasing.',
    );
  }
  final updatedChangelog = insertChangelogEntry(
    currentChangelog: currentChangelog,
    nativeHighlight: nativeHighlight,
    changed: changed,
  );

  await changelogFile.writeAsString(updatedChangelog);
  logInfo('CHANGELOG.md updated');

  return ChangelogUpdate(
    model: entry.model,
    highlightsStacked: highlightsStacked,
  );
}

/// What [releaseNotesFrom] returns when the release exists but carries no body.
///
/// A constant rather than a literal because [_fetchReleaseNotes] tests for it
/// to decide whether to go looking in the repository itself.
const emptyReleaseNotesPlaceholder =
    'No release notes were published for this release.';

/// Fetch release notes, from the GitHub release if it has a body and from the
/// upstream repository's own `RELEASE_NOTES.md` if it does not.
Future<String> _fetchReleaseNotes(String version) async {
  final result = await Process.run('curl', [
    '-s',
    'https://api.github.com/repos/openmls/openmls/releases/tags/$version',
  ]);

  if (result.exitCode != 0) {
    throw Exception('Failed to fetch release from GitHub');
  }

  final fromRelease = releaseNotesFrom(
    jsonDecode(result.stdout as String) as Map<String, dynamic>,
    version,
  );
  if (fromRelease != emptyReleaseNotesPlaceholder) return fromRelease;

  final fromRepo = await _fetchInRepoReleaseNotes(version);
  if (fromRepo == null) return fromRelease;
  logInfo('Release body was empty; using RELEASE_NOTES.md at $version');
  return fromRepo;
}

/// Fetch `RELEASE_NOTES.md` at [version] from the upstream repository.
///
/// Best-effort by design: an upstream that keeps no such file, a network
/// failure and a rate-limited reply all land as null and leave the caller with
/// the release body it already had.
Future<String?> _fetchInRepoReleaseNotes(String version) async {
  final result = await Process.run('curl', [
    '-s',
    '-H',
    'Accept: application/vnd.github.raw',
    'https://api.github.com/repos/openmls/openmls/contents/RELEASE_NOTES.md'
        '?ref=$version',
  ]);
  if (result.exitCode != 0) return null;
  return inRepoReleaseNotesFrom(result.stdout as String, version);
}

/// Read release notes out of the upstream repository's own `RELEASE_NOTES.md`.
///
/// Some upstreams publish every GitHub release with an EMPTY body while
/// maintaining the notes as a file at the repository root. The releases API
/// alone therefore makes every one of their bumps look like an unannounced one,
/// and the model then reports that absence as a fact about the release:
/// "upstream has no published release notes" has reached a pull request that
/// way, for a tag whose own file named three changes.
///
/// The file is overwritten each release, so the copy at a tag holds that tag's
/// bullets and nothing else. That is also the trap: a tag whose release commit
/// did not update it would hand back the PREVIOUS release's notes, which is
/// worse than none — it is wrong rather than missing. The first line is the
/// version, so the claim is checkable, and anything that does not name
/// [version] is discarded instead of guessed at.
///
/// Returns null when the file is absent, is an API error payload, or names a
/// different release. Pure; exposed for testing.
String? inRepoReleaseNotesFrom(String content, String version) {
  final text = content.trim();
  if (text.isEmpty) return null;
  // With `Accept: application/vnd.github.raw` a miss still answers JSON.
  if (text.startsWith('{')) return null;

  final lines = text.split('\n');
  final heading = lines.first.trim();
  final wanted = version.trim();
  final matches =
      heading == wanted ||
      heading == 'v$wanted' ||
      (wanted.startsWith('v') && heading == wanted.substring(1));
  if (!matches) return null;

  final body = lines.skip(1).join('\n').trim();
  return body.isEmpty ? null : body;
}

/// Read the release body out of a decoded `releases/tags/<v>` response.
///
/// Split out of the fetch so the decision can be tested without a network: the
/// fetch above is one `curl` call, and everything that can go wrong afterwards
/// is decided here.
///
/// `curl -s` carries no `-f`, so it exits 0 on 403, 429 and every 5xx — the
/// exit code says the transport worked, not that GitHub answered with a
/// release. The `Not Found` test is not enough on its own either: it matches
/// one exact string, while a rate-limited reply reads "API rate limit exceeded
/// for <ip>". Without the `tag_name` test such a reply used to fall through to
/// `body`, which is absent, and this returned "No release notes were
/// published" — an API failure laundered into a fact the changelog was then
/// written from. The request is unauthenticated, so the ceiling is 60 requests
/// an hour per IP and GitHub's runners share IPs.
///
/// `tag_name` is the discriminator rather than `body` because a real release
/// with an empty body is the ordinary case here and has to keep working,
/// whereas no error payload carries a tag name. `_fetchUpstreamCommits` tests
/// for `commits` for the same reason.
String releaseNotesFrom(Map<String, dynamic> json, String version) {
  if (json.containsKey('message') && json['message'] == 'Not Found') {
    throw Exception('Release $version not found');
  }

  if (json['tag_name'] == null) {
    throw Exception(
      'GitHub did not return a release for $version: '
      '${json['message'] ?? 'unrecognised response'}',
    );
  }

  // Some upstreams publish every release with an empty body, so this is an
  // ordinary case rather than an error. Saying so explicitly matters: an empty
  // section under a "release notes" heading reads to a model as "nothing
  // changed", when what it means is that the commit list below it is the input.
  final body = json['body'] as String? ?? '';
  return body.trim().isEmpty ? emptyReleaseNotesPlaceholder : body;
}

/// Fetch the commit list AND the changed-file list between two upstream tags.
///
/// One request answers both: the compare API returns `commits` and `files` in
/// the same payload, and the file list is what tells a reader WHERE a change
/// landed. Without it the model has only commit subject lines to go on, and a
/// subject line is not evidence of location — an entry written from one put an
/// upstream commit in the wrong crate.
Future<({String commits, String files})> _fetchUpstreamCompare(
  String from,
  String to,
) async {
  final result = await Process.run('curl', [
    '-s',
    'https://api.github.com/repos/openmls/openmls/compare/$from...$to?per_page=250',
  ]);

  if (result.exitCode != 0) {
    throw Exception('Failed to fetch compare from GitHub');
  }

  final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  if (json['commits'] == null) {
    throw Exception(json['message'] ?? 'No commits in compare response');
  }

  return (commits: upstreamCommitsFrom(json), files: upstreamFilesFrom(json));
}

/// Render the changed-file list out of a decoded compare response.
///
/// Returns an empty string when the payload carries no usable list, in which
/// case the prompt gets no file section at all rather than an empty heading.
///
/// The header says whether the list is COMPLETE, and that word is load-bearing
/// rather than decorative. The compare API caps `files` at 300 and says so
/// nowhere in the payload, so on a big range absence from this list is not
/// evidence of absence from the range — and the entry this exists to
/// improve is built on exactly that kind of negative claim ("nothing in the
/// crates we bind changed"). A model told only "here are some files" would
/// make that claim from a truncated list and be wrong. So completeness is
/// computed here, where the counts are, and stated in the text the model
/// reads: `total` against what was returned, and whether the char cap bit.
///
/// Pure; exposed for testing.
String upstreamFilesFrom(Map<String, dynamic> json) {
  final files = json['files'];
  if (files is! List || files.isEmpty) return '';

  final lines = <String>[];
  for (final file in files) {
    if (file is! Map<String, dynamic>) continue;
    final name = file['filename'];
    if (name is! String) continue;
    final status = file['status'] as String? ?? 'changed';
    final previous = file['previous_filename'];
    lines.add(
      previous is String ? '$status $previous -> $name' : '$status $name',
    );
  }
  if (lines.isEmpty) return '';

  const maxChars = 12000;
  var listing = lines.join('\n');
  var capped = false;
  if (listing.length > maxChars) {
    listing = listing.substring(0, listing.lastIndexOf('\n', maxChars));
    capped = true;
  }

  // `files` is capped at 300 by the API; a payload at that ceiling is assumed
  // incomplete even when no count says so.
  final complete = !capped && lines.length < 300;
  final header = complete
      ? 'COMPLETE — every file the range touches is listed below '
            '(${lines.length}).'
      : 'TRUNCATED — this is only part of what the range touches. Nothing '
            'below supports a claim that some path was NOT changed.';
  return '$header\n$listing';
}

/// Render the commit list out of a decoded compare response. Pure; exposed for
/// testing.
String upstreamCommitsFrom(Map<String, dynamic> json) {
  final commits = json['commits'] as List<Object?>;
  final totalCommits = json['total_commits'] as int? ?? commits.length;
  final messages = <String>[];
  for (final commit in commits) {
    final message =
        (((commit as Map<String, dynamic>)['commit']
                    as Map<String, dynamic>)['message']
                as String)
            .split('\n')
            .first
            .trim();
    if (message.startsWith('Merge ')) continue;
    messages.add('- $message');
  }

  const maxChars = 8000;
  var listing = messages.join('\n');
  if (listing.length > maxChars) {
    listing = '${listing.substring(0, maxChars)}\n- ... (truncated)';
  }
  if (totalCommits > commits.length) {
    listing += '\n- ... and ${totalCommits - commits.length} more commits';
  }
  return listing;
}

/// Where this project states what it binds and exposes, for the prompt below.
///
/// The one part of the prompt no template variable can hold. Which crates are
/// built is answerable from the generator's answers; which symbols this wrapper
/// re-exports — and, more usefully, which whole upstream areas it never touches
/// — is knowledge only this project has, and it is what rule 2 of the prompt
/// classifies every upstream change against. So the template writes the file
/// once and then never overwrites it (`_skip_if_exists`), which also means
/// `copier update` never raises a conflict over it.
const changelogScopePath = '.github/agent-prompts/changelog-scope.md';

/// The upstream crates this package builds, as the prompt should name them.
///
/// A list with a trailing comma rather than one joined string: `dart format`
/// keeps a trailing-comma literal expanded whatever its length, so the rendered
/// file is formatted identically for a project with one bound crate and for one
/// with six. A single string would be collapsed onto one line for the short
/// answer and split for the long one, and the template source can only be
/// correct for one of them.
const boundCrateNames = <String>[
  '`openmls`',
  '`openmls_rust_crypto`',
  '`openmls_basic_credential`',
  '`openmls_traits`',
  '`openmls_libcrux_crypto`',
];

/// [boundCrateNames] as the prompt writes them; empty when none are answered.
final boundCrates = boundCrateNames.join(', ');

/// Reads [changelogScopePath], falling back to the bound-crate list alone.
///
/// The fallback is deliberately weak rather than absent: with no scope section
/// at all the prompt's rule 2 would classify against nothing, and a model given
/// no list treats everything upstream as in scope — the exact failure the file
/// exists to prevent. Naming the crates at least bounds it.
String readChangelogScope({Directory? packageDir}) {
  final dir = packageDir ?? getPackageDir();
  final file = File('${dir.path}/$changelogScopePath');
  final text = file.existsSync() ? file.readAsStringSync().trim() : '';
  if (text.isNotEmpty) return text;

  logWarning('$changelogScopePath is missing; classifying on crate names only');
  const surface =
      'Exposed surface: not stated — this project has not written its scope\n'
      'file yet, so nothing here names what it re-exports. Treat any upstream\n'
      "change you cannot tie to a symbol this package exposes as INVISIBLE to\n"
      "this package's users, and say so rather than guessing.";

  if (boundCrates.isEmpty) {
    return 'This package wraps a SUBSET of what it binds.\n$surface';
  }
  return 'This package builds ONLY these upstream crates:\n'
      '$boundCrates.\n'
      'It exposes a SUBSET of what they contain.\n'
      '$surface';
}

/// The exact phrase an entry uses to state that this update leaves the
/// package's public API untouched.
///
/// Interpolated into rule 4 of the prompt AND matched by
/// [breakingContradictsNoImpact], so the two cannot drift apart: rewording the
/// rule rewords the check with it. That coupling is the point. The check reads
/// one literal phrase, so an entry that paraphrases the conclusion — "does not
/// affect", "no public-API impact" — walks straight past it, and nothing would
/// report that the guard had stopped guarding: its tests feed the function a
/// string directly and would keep passing while the prompt no longer produced
/// one it recognises.
///
/// Rule 4 carries a second precondition that is NOT checked here: the phrase is
/// false when the range changed shipped code in a bound crate. Deciding that in
/// code needs a crate-name-to-path mapping — a crate's name need not be its
/// directory in the upstream tree — and that is project knowledge this script
/// does not hold: [changelogScopePath] names the crates, not their paths. A
/// check that needed a line every existing project's scope file lacks would
/// silently pass for all of them, which is worse than asking the model, so it
/// is asked.
const noImpactPhrase = "do not affect this library's public API";

/// Where [_defaultHighlightTemplate] carries the version.
const _highlightVersionSlot = '<version>';

/// The Highlights line the prompt mandates when nothing in the update reaches
/// the exposed surface — the common case, and so the line most [Unreleased]
/// sections already carry from the previous bump.
///
/// Interpolated into rule 2 of the highlight rules AND matched by
/// [isOwnDefaultHighlight], on the same reasoning as [noImpactPhrase]: the
/// check exists to recognise this script's own boilerplate, and it can only do
/// that while the prompt and the check name one string between them.
const _defaultHighlightTemplate =
    '**openmls $_highlightVersionSlot** — internal/dependency update, '
    'no public-API impact';

/// The mandated default Highlights line for [version].
String defaultHighlightFor(String version) =>
    _defaultHighlightTemplate.replaceFirst(_highlightVersionSlot, version);

/// Whether [line] is a Highlights bullet this script wrote on an earlier bump.
///
/// Deliberately exact. Dependency bumps now accumulate on the main branch
/// between releases, so the second bump in a release window meets the first
/// one's Highlights line and the section ends up naming two upstream versions
/// at once, which has happened for real. That line is a STATE line, one per
/// release section, so the new one supersedes the old.
///
/// What it must never supersede is a REWRITTEN one. Rewrites of this entry are
/// multi-line and say something the default cannot, and dropping one by line
/// match would also leave its continuation lines behind as a dangling
/// paragraph. So the test is the prompt's mandated default at any version and
/// nothing else: anything reworded, extended or continued onto a second line
/// fails it and is left alone. Pure; exposed for testing.
bool isOwnDefaultHighlight(String line) {
  final at = _defaultHighlightTemplate.indexOf(_highlightVersionSlot);
  final prefix = '- ${_defaultHighlightTemplate.substring(0, at)}';
  final suffix = _defaultHighlightTemplate.substring(
    at + _highlightVersionSlot.length,
  );
  final trimmed = line.trimRight();
  return trimmed.length > prefix.length + suffix.length &&
      trimmed.startsWith(prefix) &&
      trimmed.endsWith(suffix);
}

/// Whether `[Unreleased]` already carries a native-library Highlights line that
/// [isOwnDefaultHighlight] will NOT supersede — a rewritten one.
///
/// Reported by the caller rather than resolved here: leaving both lines is the
/// safe outcome, but it is also a silent one, and the section would ship naming
/// two upstream versions. Pure; exposed for testing.
bool hasRewrittenNativeHighlight(String currentChangelog) {
  var inUnreleased = false;
  var inHighlights = false;
  for (final line in currentChangelog.split('\n')) {
    if (line.startsWith('## ')) {
      inUnreleased = line.startsWith('## [Unreleased]');
      inHighlights = false;
      continue;
    }
    if (!inUnreleased) continue;
    if (line.startsWith('### ')) {
      inHighlights = false;
      continue;
    }
    if (line.startsWith('#### ')) {
      inHighlights = line.contains('Highlights');
      continue;
    }
    if (inHighlights &&
        line.startsWith('- **openmls ') &&
        !isOwnDefaultHighlight(line)) {
      return true;
    }
  }
  return false;
}

/// Strip a leading Markdown list marker from a model-returned Highlights line.
///
/// [insertChangelogEntry] writes that line as `'- $nativeHighlight'`, so a
/// marker in the model's own answer renders as a nested list under an empty
/// parent bullet. It has reached a pull request that way:
/// `- - **openmls v1.2.3** — …`.
///
/// Normalised here rather than argued about in the prompt, because the prompt
/// asks for two things at once and the model is not wrong to follow either:
/// rule 1 of the highlight rules gives the line WITHOUT a marker, while the
/// current CHANGELOG is pasted above it under "match this house style exactly",
/// and every Highlights line in it begins with one.
///
/// Every `insertChangelogEntry` test feeds an already-clean string, which is
/// why the suite stayed green while this shipped. Pure; exposed for testing.
String stripLeadingListMarker(String highlight) {
  final trimmed = highlight.trim();
  final marker = RegExp(r'^(?:[-*+][ \t]+)+').firstMatch(trimmed);
  return marker == null ? trimmed : trimmed.substring(marker.end).trim();
}

/// The fields the model must return, and what each one is.
///
/// Doubles as the schema every provider enforces natively, so the JSON contract
/// is checked by the provider rather than only asked for in the prompt.
const _changelogFields = <String, String>{
  'openmls_highlight':
      'A single "#### ✨ Highlights" line for the openmls dependency.',
  'changed':
      'The "#### Changed" entry: one top-level Markdown list item with its '
      'indented sub-bullets.',
};

/// Generate the changelog entry with the configured AI model.
///
/// Returns the two fields together with the model that wrote them: without
/// recording which provider answered, entries written by different providers
/// become indistinguishable a month later, when the difference in house style
/// is the only symptom that the first provider has been failing.
Future<({String highlight, String changed, AiModel model})>
_generateChangelogEntry({
  required String version,
  required String? fromVersion,
  required String releaseNotes,
  required String upstreamCommits,
  required String upstreamFiles,
  required String currentChangelog,
  required String? codegenResult,
  required List<ResolvedAiModel> models,
}) async {
  // Extract recent changelog entries for context (first 150 lines).
  final changelogContext = currentChangelog.split('\n').take(150).join('\n');

  // Prefer a compare link (the release notes are often incomplete); fall back
  // to the release-notes link when the previous version is unknown.
  final sourceLink = fromVersion != null && fromVersion != version
      ? '[compare](https://github.com/openmls/openmls/compare/$fromVersion...$version)'
      : '[release notes](https://github.com/openmls/openmls/releases/tag/$version)';

  // Injected only when the pipeline actually ran codegen and captured the
  // result. Absent, the prompt says nothing about codegen and rule 6 forbids
  // the model from inventing it — which is what it did before this existed.
  final codegenSection = switch (codegenResult) {
    'unchanged' =>
      '''

## Binding regeneration result (a real result from this run, not an inference)
`make codegen` ran after the dependency bump and produced NO change to
`lib/src/rust/`: the FFI surface did not move. You may state this.
''',
    'changed' =>
      '''

## Binding regeneration result (a real result from this run, not an inference)
`make codegen` ran after the dependency bump and DID change `lib/src/rust/`:
the FFI surface moved. State it plainly and prefix that bullet with
"**BREAKING:**" if the change is visible to users of this package. On a plain
dependency bump this is unexpected and a reviewer needs to see it.
''',
    _ => '',
  };

  // Project-owned; see [readChangelogScope]. Read per call rather than cached
  // so editing the file takes effect without touching this script.
  final scope = readChangelogScope();

  final prompt =
      '''
You are updating CHANGELOG.md for **openmls_dart**, a Dart package
that wraps a SUBSET of openmls via Flutter Rust Bridge. It just
updated its openmls native dependency to $version.

## What this package binds and exposes (CRITICAL for classification)
$scope

Read that section for what it is: a statement of what this package can REACH —
which crates it builds, which surface it exposes — and never a report about the
release you are writing up. Where it describes what a dependency's changes
"do", it is naming what such a change is ABLE to touch, not what this version
touched. Never restate one of those sentences as a finding. If it says a
dependency can change the bytes on the wire, that is the question to answer
from the material below; it is not the answer.

Note also what that material cannot settle. The range above covers ONE
repository. A dependency that lives in a different one leaves a single trace in
it — a version number in a manifest — and nothing whatever about what changed
inside it. So where the entry would turn on that, say the material does not
carry it, and name the version move as the version move it is. Do not infer the
change from the bump, from the dependency's name, or from what the section
above says such a change can reach.

## openmls release notes for $version:
$releaseNotes
${upstreamCommits.isEmpty ? '' : '''

## Upstream commits included in this update (first lines):
$upstreamCommits

Use BOTH the release notes and the commit list — release notes are often
incomplete, and the commit list shows what actually changed.'''}
${upstreamFiles.isEmpty ? '' : '''

## Files the upstream range changed
$upstreamFiles

This is the compare API's own file list, and it is the ONLY evidence here about
WHERE a change landed. A commit subject is not: many name a change and no place
at all, and an entry that inferred the place from one put an upstream commit in
the wrong crate. Read the location off this list.

Read the first line before you rely on it. COMPLETE means the range touches
nothing else, so you may reason from a path's ABSENCE — "the crates we bind
changed only <file>" is then a checkable statement, and it is a better one than
any verdict. TRUNCATED means the opposite: the list still proves that what it
names DID change, and proves nothing at all about what it does not name, so
write no negative claim from it.

What this list does NOT carry is which commit changed which file. It is flat
across the whole range, and the commit list above carries no file list of its
own, so nothing here joins the two. Never attribute a file to a named commit,
and never take the REASON a file changed from a commit subject that happens to
sound related: a range holds unrelated commits, and pairing one commit's subject
with another commit's file invents a change nobody made. Write "the range
changes <file>" and stop there. Where the entry would turn on why a file
changed, say that this material does not say.'''}

## Current CHANGELOG.md (match this house style exactly):
$changelogContext
$codegenSection

## Your task
Return a JSON object with EXACTLY two string fields:
1. "openmls_highlight" — a single Highlights line for openmls.
2. "changed" — the "#### Changed" entry.

## Rules for "openmls_highlight"
1. Format exactly: "**openmls $version** — <brief 3-7 word description>".
2. If nothing in this update touches our exposed surface (the common case), use:
   "${defaultHighlightFor(version)}".
3. Return the line WITHOUT a leading "- ". The list marker is added when the
   line is written into the file; one in your answer makes it "- - **…".

## Rules for "changed" (THIS IS THE IMPORTANT PART — match the house style)
1. Write ONE bullet in the house format every bullet in the entries above
   follows: "- **<summary>** — <detail>". The summary is a short sentence
   saying what this update means FOR THIS PACKAGE, written fresh each release;
   it is never a fixed string, and "Update <library> to <version>" is a title,
   not a summary. Put $sourceLink in the detail so a reader can reach the range.
   Longer entries continue in paragraphs indented two spaces and separated by a
   blank line — use those, not nested sub-bullets.
2. Classify EVERY upstream change against the scope section above:
   - A change earns its own bullet only when BOTH hold: (a) it lands in a crate
     we bind, AND (b) it changes something named under "Exposed surface" above.
     Landing in a bound crate is NOT sufficient on its own — most of what those
     crates contain is never reached from this package. If you cannot name the
     specific item from "Exposed surface" that the change touches, it is out of
     scope.
   - Out-of-scope work is excluded BY MECHANISM, never by caption. Do not name
     the areas and append a verdict — "none of which this library exposes", "not
     relevant here", "internal only". A verdict reads the same whatever the
     release contains, so it gives a reader nothing to check, and it is the one
     failure this prompt exists to prevent. Say instead WHERE the change landed
     (the crate, module or bridge) and WHY that place is out of reach: the crate
     is absent from this package's dependency graph, or the symbol is not on the
     exposed surface. Both halves are required — a location with no reason is
     still a caption.
   - Group rather than enumerate: areas that miss for the SAME reason belong in
     one sentence that gives that reason once. Length is not the goal; a reader
     being able to verify the exclusion is.
   - Prefix a bullet with "**BREAKING:**" only when a caller of THIS package
     would have to change their code. A symbol removed or altered upstream that
     this package never calls is not breaking here, whatever upstream calls it.
   - Never emit a "**BREAKING:**" bullet together with the rule-4 sentence: if
     something genuinely broke, the update by definition DOES affect this
     package's public API, and that sentence must be omitted.
3. When the crates we bind had no change reaching our exposed surface, say so
   explicitly. Default wording, which is true whenever (b) in rule 2 failed:
   "The crates we bind (`openmls`, `openmls_rust_crypto`, `openmls_basic_credential`, `openmls_traits`, `openmls_libcrux_crypto`) have no changes reaching the surface this package exposes".
   Use the STRONGER "are unchanged apart from version strings" ONLY when those
   crates genuinely had no code change at all. Those are different claims, and
   the strong one is checkable: if a bound crate lost or altered any symbol —
   even one this package never calls — it is FALSE and must not be written.
   Naming such a symbol and saying why it does not reach us is better than
   claiming nothing changed.
   Where a COMPLETE file list appears above, neither stock sentence is your best
   answer: say which files in those crates the range actually changed, because
   that is checkable and a verdict is not. "Between them the range changes
   exactly one file, and it is the version string" is the shape to aim for.
4. When it is true, state that conclusion ONCE, and in these exact words:
       $noImpactPhrase
   Write that phrase verbatim, as the close of a sentence you are already
   making ("... so these changes do not affect this library's public API") —
   not as a detached trailing "Note:" line. The wording is load-bearing: a check
   in this script reads that exact phrase to catch an entry which claims a
   breaking change and no API impact at the same time, and any paraphrase
   ("does not affect", "no public-API impact", "the public API is untouched")
   defeats that check silently.
   ONCE means once. The Highlights line, the mechanism you gave under rule 2 and
   this conclusion are three different statements; repeating the same verdict in
   more than one of them is padding, and it is what makes these entries read as
   filled-in boilerplate. Omit the phrase entirely when it is not true.
   Two things above can make it false, and you can check both. First, a
   COMPLETE file list in which a crate named under "Crates bound:" has any
   SOURCE file changed — source meaning a file that is neither a version string
   nor a test. That is the update reaching this package, whatever you conclude
   about which surface it reaches. Second, an unchanged FFI surface offered as
   the ground for the phrase: a signature can stay identical while the
   behaviour behind it changes, and a caller sees that change, so clean codegen
   alone never licenses it. What does license it is the file list — a COMPLETE
   list whose bound crates show nothing but version strings and tests. Where
   either failing case holds, drop the phrase and say what moved instead.
5. Judge relevance from the release notes AND the commit list, NOT from the
   version numbers.
6. Claim only what the material above supports. Where a "Binding
   regeneration result" section appears above, that is a real result from this
   run — report it. Where it does NOT appear, say nothing whatsoever about
   `make codegen`, binding diffs or the FFI surface, however often the entries
   above mention them: a human ran those and you did not. Copy the style, never
   a finding.
7. The sections above are your INPUTS. Their state is a fact about this
   script's fetch, never a fact about the release, so the entry must not
   narrate it. "Upstream has no published release notes", "the commit list was
   truncated", "no compare link was available" tell a reader something about
   how this ran and nothing about the dependency — and the first of those is
   not even reliable: some upstreams publish every release with an empty body
   while maintaining the notes elsewhere. When the release-notes section says
   nothing was published, write the entry from the commit list and do not
   remark on the absence.

## The shape of "changed" (the SHAPE is fixed; the wording is yours every time)

One house-format bullet, continued in indented paragraphs when it needs them:

  - **<what this update means for this package>** — <the range, with
    $sourceLink, then the mechanism: where the out-of-scope work landed and why
    that place is out of reach>

    <continuation: what the crates we bind did and did not change; the
    binding-regeneration result, if one is given above; and the rule-4
    conclusion, if it is true>

Inside the JSON string a newline is written \\n, and a continuation paragraph is
a blank line followed by two spaces of indent.

## What NOT to write

This is the shape that keeps reaching pull requests. Every line of it is a
verdict with nothing behind it:

  - Update openmls native library to $version ($sourceLink)
    - Upstream changes cover <areas> — none of which this library exposes
    - The crates we bind (`openmls`, `openmls_rust_crypto`, `openmls_basic_credential`, `openmls_traits`, `openmls_libcrux_crypto`) have no changes reaching the surface this package exposes
    - Note: These changes do not affect this library's public API

Four things are wrong with it. The first line is a title, not the house
"**summary** — detail" bullet (rule 1). The areas are named and then dismissed
by caption instead of by location and reason (rule 2). The same no-impact
verdict is stated three times over (rule 4). And it comes out word for word
identical release after release, which is the tell that no release was read.

The rule-4 phrase itself is still REQUIRED when true. What is wrong above is
that it arrives as a detached trailing line rather than as the conclusion of an
argument you actually made.

Return ONLY valid JSON with the two fields named under "Your task", no markdown
code blocks.
''';

  final response = await callAi(
    models: models,
    prompt: prompt,
    jsonFields: _changelogFields,
  );

  final parsed = decodeAiJsonObject(response.text);
  final highlight = parsed?['openmls_highlight'];
  final changed = parsed?['changed'];

  // Both fields are required, and nothing is salvaged from a partial answer.
  // The previous version wrote whatever it got straight into the "changed"
  // field, which turned a malformed answer into a malformed CHANGELOG. Failing
  // here instead leaves the entry unwritten and the pull request labelled for
  // a human — a state the workflow already handles.
  if (highlight is! String ||
      highlight.trim().isEmpty ||
      changed is! String ||
      changed.trim().isEmpty) {
    throw AiCallException(
      '${response.model} answered without the required fields '
      '(${_changelogFields.keys.join(', ')}).',
    );
  }

  // A `**BREAKING:**` bullet and the "does not affect this library's public
  // API" note cannot both be true of one entry, and a model that writes both
  // has misjudged one of them. Observed for real: a run labelled the removal of
  // a helper in a bound crate BREAKING and then closed with the no-impact
  // note. The helper sits in a crate this package binds but not on the surface
  // it exposes, so nothing here broke — the model collapsed the two conditions
  // in rule 2 into one.
  //
  // Checked in code rather than only asked for in the prompt, because the
  // contradiction is decidable from the text alone. Telling users a release is
  // breaking when it is not is the expensive outcome; failing here leaves the
  // entry unwritten and the pull request labelled for a human, which is the
  // path a malformed answer already takes.
  if (breakingContradictsNoImpact(changed)) {
    throw AiCallException(
      '${response.model} marked a change **BREAKING:** and also stated the '
      "update does not affect this package's public API. Only one can hold: a "
      'change is breaking here only when it touches the exposed surface, not '
      'merely because it lands in a bound crate.',
    );
  }

  return (
    highlight: stripLeadingListMarker(highlight),
    changed: changed.trimRight(),
    model: response.model,
  );
}

/// Whether [changed] both claims a breaking change and claims the update leaves
/// the public API untouched. Pure; exposed for testing.
///
/// Apostrophes are normalised before matching. The prompt asks for a straight
/// one and the example shows a straight one, but a model writing prose reaches
/// for the typographic `’` often enough — and a check that a curly quote walks
/// straight through is worse than no check, because the contradiction it exists
/// to catch would then publish while this reads as though it were guarded.
bool breakingContradictsNoImpact(String changed) {
  final lower = changed.toLowerCase().replaceAll(RegExp('[‘’ʼ]'), "'");
  return lower.contains('**breaking:**') &&
      lower.contains(noImpactPhrase.toLowerCase());
}

/// Insert the new changelog entry in the correct location. Pure; exposed for
/// testing.
///
/// Strategy:
/// 1. If [Unreleased] section exists, add entry to Highlights and Changed,
///    creating whichever are missing. A missing `### For Users` is created at the
///    top of the section, ahead of any `### For Contributors`, matching the order
///    of the released sections; missing subsections are placed by the same rule
///    inside it (Highlights → Changed (Breaking) → Changed → Security → Fixed).
///    `#### Changed` is matched exactly — `#### Changed (Breaking)` is a
///    different subsection and never receives the entry.
/// 2. If no [Unreleased] section, create it before first version (this is the
///    normal path after a release, which no longer leaves an empty
///    `## [Unreleased]` behind).
String insertChangelogEntry({
  required String currentChangelog,
  required String nativeHighlight,
  required String changed,
}) {
  final lines = currentChangelog.split('\n');

  final hasUnreleased = lines.any((l) => l.startsWith('## [Unreleased]'));

  if (hasUnreleased) {
    return _insertIntoUnreleased(lines, nativeHighlight, changed);
  } else {
    return _createUnreleasedSection(lines, nativeHighlight, changed);
  }
}

/// Insert entry into an existing [Unreleased] section.
String _insertIntoUnreleased(
  List<String> lines,
  String nativeHighlight,
  String changed,
) {
  final result = <String>[];
  var inUnreleased = false;
  var inForUsers = false;
  var insertedHighlights = false;
  var insertedChanged = false;
  // Whether the line being read sits under `#### ✨ Highlights`, which is the
  // only block a superseded native-library line may be dropped from.
  var inHighlights = false;
  // Index of the `## [Unreleased]` heading within [result], so a missing
  // `### For Users` can be spliced at the top of the section, not the bottom.
  var unreleasedIdx = -1;
  // Index of the `### For Users` heading within [result], so a missing
  // `#### ✨ Highlights` can be spliced at the top of that block.
  var forUsersIdx = -1;
  // Where a missing `#### Changed` belongs: just before the first For Users
  // subsection that follows it in the documented order. -1 until one is seen,
  // in which case the flush falls back to the end of the block.
  var changedAnchorIdx = -1;

  // The end of what has been emitted so far, backed up over trailing blanks so
  // an insertion there keeps the blank line separating it from what follows.
  int trimmedEnd() {
    var at = result.length;
    while (at > 0 && result[at - 1].trim().isEmpty) {
      at--;
    }
    return at;
  }

  // Splice whichever subsection is still missing into the existing
  // `### For Users` block. The later index goes first: inserting at the top of
  // the block would shift `changedAnchorIdx` out from under the second insert.
  void flushForUsers() {
    if (!insertedChanged) {
      final at = changedAnchorIdx >= 0 ? changedAnchorIdx : trimmedEnd();
      result.insertAll(at, ['', '#### Changed', '', changed]);
      insertedChanged = true;
    }
    if (!insertedHighlights) {
      result.insertAll(forUsersIdx + 1, [
        '',
        '#### ✨ Highlights',
        '',
        '- $nativeHighlight',
      ]);
      insertedHighlights = true;
    }
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    // Check for ## [Unreleased] section.
    if (line.startsWith('## [Unreleased]')) {
      inUnreleased = true;
      result.add(line);
      unreleasedIdx = result.length - 1;
      continue;
    }

    // Check for next version section (end of Unreleased).
    if (inUnreleased &&
        line.startsWith('## [') &&
        !line.contains('Unreleased')) {
      // If we haven't inserted yet, create the structure.
      if (!insertedHighlights || !insertedChanged) {
        if (forUsersIdx >= 0) {
          // A `### For Users` heading exists and runs to the end of the
          // section, so only its missing subsections have to be created.
          // Adding another `### For Users` would duplicate the heading.
          flushForUsers();
        } else {
          // No `### For Users` anywhere in [Unreleased]. Create it at the TOP of
          // the section rather than here at the bottom: appending would file a
          // user-facing entry below every existing subsection (`### For
          // Contributors`), and every released section puts For Users first.
          result.insertAll(unreleasedIdx + 1, [
            '',
            '### For Users',
            '',
            '#### ✨ Highlights',
            '',
            '- $nativeHighlight',
            '',
            '#### Changed',
            '',
            changed,
          ]);
          insertedHighlights = true;
          insertedChanged = true;
        }
      }
      inUnreleased = false;
      inForUsers = false;
      inHighlights = false;
      result.add(line);
      continue;
    }

    // Check for ### For Users in Unreleased.
    if (inUnreleased && line.startsWith('### For Users')) {
      inForUsers = true;
      result.add(line);
      forUsersIdx = result.length - 1;
      continue;
    }

    // Check for next ### section (end of For Users).
    if (inForUsers && line.startsWith('### ') && !line.contains('For Users')) {
      // If we haven't inserted yet, insert before this section.
      if (!insertedHighlights || !insertedChanged) {
        flushForUsers();
      }
      inForUsers = false;
      inHighlights = false;
      result.add(line);
      continue;
    }

    // Check for #### ✨ Highlights in For Users.
    if (inForUsers && line.contains('Highlights')) {
      result.add(line);
      result.add('');
      result.add('- $nativeHighlight');
      insertedHighlights = true;
      inHighlights = true;
      // Skip the next empty line if present.
      if (i + 1 < lines.length && lines[i + 1].trim().isEmpty) {
        i++;
      }
      continue;
    }

    // Check for #### Changed in For Users. Matched exactly, because
    // `#### Changed (Breaking)` is a different subsection: filing a routine
    // native-library bump under it would announce it as a breaking change. A
    // missing `#### ✨ Highlights` is NOT created here — the flush puts it at
    // the top of the block, which is where the documented order wants it even
    // when `#### Changed` is preceded by the breaking one.
    // A native-library Highlights line from an earlier bump in the same release
    // window is superseded by the one just inserted: that line names the
    // version the section ships, so two of them make the section name two.
    // Only this script's own mandated default matches — see
    // [isOwnDefaultHighlight] — so a rewritten line is never dropped here.
    if (inHighlights && insertedHighlights && isOwnDefaultHighlight(line)) {
      continue;
    }

    if (inForUsers &&
        line.startsWith('#### ') &&
        !line.contains('Highlights')) {
      inHighlights = false;
    }

    if (inForUsers && line.trimRight() == '#### Changed') {
      result.addAll([line, '', changed]);
      insertedChanged = true;
      // Skip the next empty line if present.
      if (i + 1 < lines.length && lines[i + 1].trim().isEmpty) {
        i++;
      }
      continue;
    }

    // A `#### Changed` that has to be created belongs just before the first
    // heading that FOLLOWS it in the documented order (`#### Security`,
    // `#### Fixed`, `#### Documentation`, …), so that first one anchors it.
    //
    // ⚠ [precedesChanged] is therefore not a courtesy list: a subsection that
    // comes BEFORE `#### Changed` and is missing from it becomes the anchor,
    // and the created `#### Changed` is then filed above it — out of the order
    // this script and CLAUDE.md both state. `#### ✨ Highlights` cannot reach
    // here (it is consumed above), but `#### Added` can, and did.
    if (inForUsers &&
        !insertedChanged &&
        changedAnchorIdx < 0 &&
        line.startsWith('#### ') &&
        !precedesChanged(line)) {
      changedAnchorIdx = trimmedEnd();
    }

    result.add(line);
  }

  return result.join('\n');
}

/// Whether `line` is a `### For Users` subsection that precedes `#### Changed`
/// in the order `CLAUDE.md` documents (Highlights → Added → Changed (Breaking)
/// → Changed → Security → Fixed → Documentation).
///
/// Used to decide what may anchor a created `#### Changed`. Keep it in step
/// with that order: a subsection added before `#### Changed` and not listed
/// here silently files new entries above it.
bool precedesChanged(String line) =>
    line.startsWith('#### Changed (') ||
    line.trimRight() == '#### Added' ||
    line.contains('Highlights');

/// Create a new [Unreleased] section at the top.
String _createUnreleasedSection(
  List<String> lines,
  String nativeHighlight,
  String changed,
) {
  final result = <String>[];

  // Find the first version line (## [X.Y.Z]).
  var insertIndex = 0;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('## [') && !lines[i].contains('Unreleased')) {
      insertIndex = i;
      break;
    }
  }

  // Add lines before first version, Unreleased section, and remaining lines.
  result
    ..addAll(lines.sublist(0, insertIndex))
    ..addAll([
      '## [Unreleased]',
      '',
      '### For Users',
      '',
      '#### ✨ Highlights',
      '',
      '- $nativeHighlight',
      '',
      '#### Changed',
      '',
      changed,
      '',
    ])
    ..addAll(lines.sublist(insertIndex));

  return result.join('\n');
}
