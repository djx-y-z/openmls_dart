// Update CHANGELOG.md with AI-generated entry for openmls update.
//
// Uses GitHub Models API (OpenAI-compatible) to analyze release notes
// and generate appropriate changelog entries.
library;

import 'dart:convert';
import 'dart:io';

import 'common.dart';

/// Update CHANGELOG.md with a new openmls version entry
Future<void> updateChangelog({
  required String version,
  required String token,
  bool ciMode = false,
}) async {
  final packageDir = getPackageDir();

  // Step 1: Read current openmls_frb version from Cargo.toml
  logStep('Reading openmls_frb version from rust/Cargo.toml...');
  final frbVersion = _readFrbVersion(packageDir);
  logInfo('Current openmls_frb version: $frbVersion');

  // Step 2: Fetch release notes from GitHub
  logStep('Fetching release notes for $version...');
  final releaseNotes = await _fetchReleaseNotes(version);
  logInfo('Got ${releaseNotes.length} characters of release notes');

  // Step 3: Read current CHANGELOG
  logStep('Reading CHANGELOG.md...');
  final changelogFile = File('${packageDir.path}/CHANGELOG.md');
  final currentChangelog = changelogFile.readAsStringSync();

  // Step 4: Analyze with AI
  logStep('Analyzing with GitHub Models AI...');
  final aiResponse = await _generateChangelogEntry(
    version: version,
    frbVersion: frbVersion,
    releaseNotes: releaseNotes,
    currentChangelog: currentChangelog,
    token: token,
  );

  // Parse AI response
  final parsed = jsonDecode(aiResponse) as Map<String, dynamic>;
  final nativeHighlight = parsed['openmls_highlight'] as String;
  final frbHighlight = parsed['frb_highlight'] as String;
  final changed = parsed['changed'] as String;
  logInfo('Generated openmls highlight: $nativeHighlight');
  logInfo('Generated openmls_frb highlight: $frbHighlight');
  logInfo('Generated changed entry');

  // Step 5: Update CHANGELOG
  logStep('Updating CHANGELOG.md...');
  final updatedChangelog = _insertChangelogEntry(
    currentChangelog: currentChangelog,
    nativeHighlight: nativeHighlight,
    frbHighlight: frbHighlight,
    changed: changed,
    version: version,
  );

  await changelogFile.writeAsString(updatedChangelog);
  logInfo('CHANGELOG.md updated');
}

/// Read openmls_frb version from rust/Cargo.toml
String _readFrbVersion(Directory packageDir) {
  final cargoToml = File('${packageDir.path}/rust/Cargo.toml');
  final content = cargoToml.readAsStringSync();

  // Match version = "X.Y.Z" at the start of the file (package version)
  final match = RegExp(
    r'^version\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(content);

  if (match == null) {
    throw Exception('Could not find version in rust/Cargo.toml');
  }

  return match.group(1)!;
}

/// Fetch release notes from GitHub API
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

  return json['body'] as String? ?? 'No release notes available.';
}

/// Generate changelog entry using GitHub Models API
Future<String> _generateChangelogEntry({
  required String version,
  required String frbVersion,
  required String releaseNotes,
  required String currentChangelog,
  required String token,
}) async {
  // Extract recent changelog entries for context (first 150 lines)
  final changelogContext = currentChangelog.split('\n').take(150).join('\n');

  final prompt =
      '''
You are updating CHANGELOG.md for a Dart library that wraps openmls.

The library just updated its openmls native dependency to $version.
The Rust FFI bindings crate (openmls_frb) version is $frbVersion.

## openmls Release Notes for $version:
$releaseNotes

## Current CHANGELOG.md format (for reference):
$changelogContext

## CHANGELOG Structure:
This project uses the following CHANGELOG structure:
- "### For Users" — changes that affect library users (API, behavior, dependencies)
  - "#### Highlights" — TWO lines: one for openmls version, one for openmls_frb version
  - "#### Added" — new features
  - "#### Changed" — updates to existing functionality (INCLUDING dependency updates like openmls)
  - "#### Fixed" — bug fixes
  - "#### Security" — security-related changes
- "### For Contributors" — changes that only affect developers (CI, tooling, internal refactoring)

Updating openmls version goes under "### For Users" with BOTH:
- "#### ✨ Highlights" — TWO brief one-liners (openmls AND openmls_frb)
- "#### Changed" — detailed description with release notes

## Your Task:
Generate a JSON object with THREE fields:
1. "openmls_highlight" — a single line for openmls (format: "**openmls vX.Y.Z** — brief description")
2. "frb_highlight" — a single line for openmls_frb (format: "**openmls_frb vX.Y.Z** — Rust FFI bindings")
3. "changed" — the detailed entry for Changed section

## Example output format:
```json
{
  "openmls_highlight": "**openmls v1.0.0** — latest upstream native library",
  "frb_highlight": "**openmls_frb v1.0.2** — Rust FFI bindings",
  "changed": "- Update openmls native library to v1.0.0 ([release notes](https://github.com/openmls/openmls/releases/tag/v1.0.0))\n  - Feature X: Description of feature\n  - Feature Y: Another feature\n  - Note: These changes improve performance and stability"
}
```

## Rules for "openmls_highlight":
1. Format: "**openmls $version** — [brief 3-7 word description]"
2. Keep it very short and scannable
3. Examples: "latest upstream native library", "security fixes and improvements", "new API support"

## Rules for "frb_highlight":
1. Format: "**openmls_frb v$frbVersion** — Rust FFI bindings"
2. Always use exactly this format

## Rules for "changed":
1. Start with "- Update openmls native library to $version ([release notes](...))
2. Add 2-5 bullet points summarizing key changes from release notes
3. Focus on changes relevant to library users (API changes, new features, bug fixes)
4. For internal changes, add "Note: These changes do not affect this library's API"
5. Use technical but concise language
6. Mention specific components or modules changed

Return ONLY valid JSON, no markdown code blocks.
''';

  final requestBody = jsonEncode({
    'model': 'gpt-4o-mini',
    'messages': [
      {'role': 'user', 'content': prompt},
    ],
    'temperature': 0.3,
    'max_tokens': 500,
  });

  final result = await Process.run('curl', [
    '-s',
    '-X',
    'POST',
    'https://models.github.ai/inference/chat/completions',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer $token',
    '-d',
    requestBody,
  ]);

  if (result.exitCode != 0) {
    throw Exception('GitHub Models API request failed');
  }

  final response = jsonDecode(result.stdout as String) as Map<String, dynamic>;

  if (response.containsKey('error')) {
    final error = response['error'] as Map<String, dynamic>;
    throw Exception('API error: ${error['message']}');
  }

  final choices = response['choices'] as List<Object?>?;
  if (choices == null || choices.isEmpty) {
    throw Exception('No response from AI');
  }

  final firstChoice = choices[0];
  if (firstChoice is! Map<String, dynamic>) {
    throw Exception('Invalid response format from AI');
  }
  final message = firstChoice['message'] as Map<String, dynamic>?;
  if (message == null) {
    throw Exception('No message in AI response');
  }
  final content = (message['content'] as String).trim();

  // Parse JSON response
  try {
    final parsed = jsonDecode(content) as Map<String, dynamic>;
    return jsonEncode(parsed); // Return normalized JSON
  } catch (e) {
    // If AI didn't return valid JSON, try to extract it
    final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(content);
    if (jsonMatch != null) {
      return jsonMatch.group(0)!;
    }
    // Fallback: return default format
    return jsonEncode({
      'openmls_highlight': '**openmls $version** — upstream library update',
      'frb_highlight': '**openmls_frb v$frbVersion** — Rust FFI bindings',
      'changed': content,
    });
  }
}

/// Insert the new changelog entry in the correct location
///
/// Strategy:
/// 1. If [Unreleased] section exists, add entry to Highlights and Changed
/// 2. If no [Unreleased] section, create it before first version
String _insertChangelogEntry({
  required String currentChangelog,
  required String nativeHighlight,
  required String frbHighlight,
  required String changed,
  required String version,
}) {
  final lines = currentChangelog.split('\n');

  // Check if [Unreleased] section exists
  final hasUnreleased = lines.any((l) => l.startsWith('## [Unreleased]'));

  if (hasUnreleased) {
    return _insertIntoUnreleased(lines, nativeHighlight, frbHighlight, changed);
  } else {
    return _createUnreleasedSection(
      lines,
      nativeHighlight,
      frbHighlight,
      changed,
    );
  }
}

/// Insert entry into existing [Unreleased] section
String _insertIntoUnreleased(
  List<String> lines,
  String nativeHighlight,
  String frbHighlight,
  String changed,
) {
  final result = <String>[];
  var inUnreleased = false;
  var inForUsers = false;
  var insertedHighlights = false;
  var insertedChanged = false;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    // Check for ## [Unreleased] section
    if (line.startsWith('## [Unreleased]')) {
      inUnreleased = true;
      result.add(line);
      continue;
    }

    // Check for next version section (end of Unreleased)
    if (inUnreleased &&
        line.startsWith('## [') &&
        !line.contains('Unreleased')) {
      // If we haven't inserted yet, create the structure
      if (!insertedHighlights || !insertedChanged) {
        result.addAll([
          '',
          '### For Users',
          '',
          '#### ✨ Highlights',
          '',
          '- $nativeHighlight',
          '- $frbHighlight',
          '',
          '#### Changed',
          '',
          changed,
          '',
        ]);
        insertedHighlights = true;
        insertedChanged = true;
      }
      inUnreleased = false;
      inForUsers = false;
      result.add(line);
      continue;
    }

    // Check for ### For Users in Unreleased
    if (inUnreleased && line.startsWith('### For Users')) {
      inForUsers = true;
      result.add(line);
      continue;
    }

    // Check for next ### section (end of For Users)
    if (inForUsers && line.startsWith('### ') && !line.contains('For Users')) {
      // If we haven't inserted yet, insert before this section
      if (!insertedHighlights || !insertedChanged) {
        result.addAll([
          '',
          '#### ✨ Highlights',
          '',
          '- $nativeHighlight',
          '- $frbHighlight',
          '',
          '#### Changed',
          '',
          changed,
          '',
        ]);
        insertedHighlights = true;
        insertedChanged = true;
      }
      inForUsers = false;
      result.add(line);
      continue;
    }

    // Check for #### ✨ Highlights in For Users
    if (inForUsers && line.contains('Highlights')) {
      result.add(line);
      result.add('');
      result.add('- $nativeHighlight');
      result.add('- $frbHighlight');
      insertedHighlights = true;
      // Skip the next empty line if present
      if (i + 1 < lines.length && lines[i + 1].trim().isEmpty) {
        i++;
      }
      continue;
    }

    // Check for #### Changed in For Users
    if (inForUsers && line.startsWith('#### Changed')) {
      // If Highlights wasn't found, add it before Changed
      if (!insertedHighlights) {
        result.addAll([
          '',
          '#### ✨ Highlights',
          '',
          '- $nativeHighlight',
          '- $frbHighlight',
          '',
        ]);
        insertedHighlights = true;
      }
      result.addAll([line, '', changed]);
      insertedChanged = true;
      // Skip the next empty line if present
      if (i + 1 < lines.length && lines[i + 1].trim().isEmpty) {
        i++;
      }
      continue;
    }

    result.add(line);
  }

  return result.join('\n');
}

/// Create new [Unreleased] section at the top
String _createUnreleasedSection(
  List<String> lines,
  String nativeHighlight,
  String frbHighlight,
  String changed,
) {
  final result = <String>[];

  // Find the first version line (## [X.Y.Z])
  var insertIndex = 0;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('## [') && !lines[i].contains('Unreleased')) {
      insertIndex = i;
      break;
    }
  }

  // Add lines before first version, Unreleased section, and remaining lines
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
      '- $frbHighlight',
      '',
      '#### Changed',
      '',
      changed,
      '',
    ])
    ..addAll(lines.sublist(insertIndex));

  return result.join('\n');
}
