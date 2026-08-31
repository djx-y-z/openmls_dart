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
/// Returns the model that wrote the entry, so a caller can publish it.
Future<AiModel> updateChangelog({
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
  if (fromVersion != null && fromVersion != version) {
    logStep('Fetching upstream commits $fromVersion...$version...');
    try {
      upstreamCommits = await _fetchUpstreamCommits(fromVersion, version);
      logInfo('Got ${upstreamCommits.length} characters of commit history');
    } catch (e) {
      logWarning('Could not fetch upstream commit list: $e');
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
  final updatedChangelog = insertChangelogEntry(
    currentChangelog: currentChangelog,
    nativeHighlight: nativeHighlight,
    changed: changed,
  );

  await changelogFile.writeAsString(updatedChangelog);
  logInfo('CHANGELOG.md updated');

  return entry.model;
}

/// Fetch release notes from the GitHub API.
Future<String> _fetchReleaseNotes(String version) async {
  final result = await Process.run('curl', [
    '-s',
    'https://api.github.com/repos/openmls/openmls/releases/tags/$version',
  ]);

  if (result.exitCode != 0) {
    throw Exception('Failed to fetch release from GitHub');
  }

  final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;

  if (json.containsKey('message') && json['message'] == 'Not Found') {
    throw Exception('Release $version not found');
  }

  // Some upstreams publish every release with an empty body, so this is an
  // ordinary case rather than an error. Saying so explicitly matters: an empty
  // section under a "release notes" heading reads to a model as "nothing
  // changed", when what it means is that the commit list below it is the input.
  final body = json['body'] as String? ?? '';
  return body.trim().isEmpty
      ? 'No release notes were published for this release.'
      : body;
}

/// Fetch the commit list between two upstream tags via the GitHub compare API.
///
/// Returns a newline-separated list of first-line commit messages (merge
/// commits excluded), capped to keep the AI prompt within limits.
Future<String> _fetchUpstreamCommits(String from, String to) async {
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

## openmls release notes for $version:
$releaseNotes
${upstreamCommits.isEmpty ? '' : '''

## Upstream commits included in this update (first lines):
$upstreamCommits

Use BOTH the release notes and the commit list — release notes are often
incomplete, and the commit list shows what actually changed.'''}

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
   "**openmls $version** — internal/dependency update, no public-API impact".

## Rules for "changed" (THIS IS THE IMPORTANT PART — match the house style)
1. First line exactly: "- Update openmls native library to $version ($sourceLink)".
2. Classify EVERY upstream change against the scope section above:
   - Changes OUTSIDE our exposed surface: do NOT give them their own feature
     bullets. Summarize them together in ONE bullet that ends with
     "— none of which this library exposes".
   - A change earns its own bullet only when BOTH hold: (a) it lands in a crate
     we bind, AND (b) it changes something named under "Exposed surface" above.
     Landing in a bound crate is NOT sufficient on its own — most of what those
     crates contain is never reached from this package.
     If you cannot name the specific item from "Exposed surface" that the change
     touches, treat it as invisible and fold it into the
     "— none of which this library exposes" bullet.
   - Prefix a bullet with "**BREAKING:**" only when a caller of THIS package
     would have to change their code. A symbol removed or altered upstream that
     this package never calls is not breaking here, whatever upstream calls it.
   - Never emit a "**BREAKING:**" bullet together with the rule-4 note: if
     something genuinely broke, the update by definition DOES affect this
     package's public API, and the note must be omitted.
3. When the crates we bind had no change reaching our exposed surface, say so
   explicitly. Default wording, which is true whenever (b) in rule 2 failed:
   "The crates we bind (`openmls`, `openmls_rust_crypto`, `openmls_basic_credential`, `openmls_traits`, `openmls_libcrux_crypto`) have no changes reaching the surface this package exposes".
   Use the STRONGER "are unchanged apart from version strings" ONLY when those
   crates genuinely had no code change at all. Those are different claims, and
   the strong one is checkable: if a bound crate lost or altered any symbol —
   even one this package never calls — it is FALSE and must not be written.
   Naming such a symbol and saying why it does not reach us is better than
   claiming nothing changed.
4. End with "Note: These changes do not affect this library's public API" when
   true.
5. Judge relevance from the release notes AND the commit list, NOT from the
   version numbers.
6. Claim only what the material above supports. Where a "Binding
   regeneration result" section appears above, that is a real result from this
   run — report it. Where it does NOT appear, say nothing whatsoever about
   `make codegen`, binding diffs or the FFI surface, however often the entries
   above mention them: a human ran those and you did not. Copy the style, never
   a finding.

## Example output (house style — follow this SHAPE, not this wording):
```json
{
  "openmls_highlight": "**openmls $version** — internal/dependency update, no public-API impact",
  "changed": "- Update openmls native library to $version ($sourceLink)\\n  - Upstream changes are limited to <name the areas, from the \\"Not bound or exposed\\" list above> — none of which this library exposes\\n  - The crates we bind (`openmls`, `openmls_rust_crypto`, `openmls_basic_credential`, `openmls_traits`, `openmls_libcrux_crypto`) have no changes reaching the surface this package exposes\\n  - Note: These changes do not affect this library's public API"
}
```

Return ONLY valid JSON, no markdown code blocks.
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
    highlight: highlight.trim(),
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
      lower.contains("do not affect this library's public api");
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
      result.add(line);
      continue;
    }

    // Check for #### ✨ Highlights in For Users.
    if (inForUsers && line.contains('Highlights')) {
      result.add(line);
      result.add('');
      result.add('- $nativeHighlight');
      insertedHighlights = true;
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
    if (inForUsers && line.trimRight() == '#### Changed') {
      result.addAll([line, '', changed]);
      insertedChanged = true;
      // Skip the next empty line if present.
      if (i + 1 < lines.length && lines[i + 1].trim().isEmpty) {
        i++;
      }
      continue;
    }

    // Any other `####` heading inside For Users (`#### Security`,
    // `#### Fixed`, …) follows `#### Changed` in the documented order, so a
    // `#### Changed` that has to be created belongs just before the first of
    // them. `#### Changed (Breaking)` precedes it and so does not anchor.
    if (inForUsers &&
        !insertedChanged &&
        changedAnchorIdx < 0 &&
        line.startsWith('#### ') &&
        !line.startsWith('#### Changed (')) {
      changedAnchorIdx = trimmedEnd();
    }

    result.add(line);
  }

  return result.join('\n');
}

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
