/// Template update checking utilities.
///
/// Provides functions to check for new versions of the copier template
/// and output results for CI/CD workflows.
library;

import 'dart:convert';
import 'dart:io';

import 'common.dart';

/// Path to copier answers file.
const _copierAnswersFile = '.copier-answers.yml';

/// Result of checking for template updates.
class TemplateCheckResult {
  const TemplateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.needsUpdate,
    required this.templateRepo,
    required this.releaseUrl,
    required this.compareUrl,
    this.changelog = '',
  });

  /// Current template version from .copier-answers.yml (_commit).
  final String currentVersion;

  /// Latest version from template GitHub releases.
  final String latestVersion;

  /// Whether an update is needed.
  final bool needsUpdate;

  /// GitHub owner/repo of the template.
  final String templateRepo;

  /// URL to the latest release page.
  final String releaseUrl;

  /// URL to compare current vs latest versions.
  final String compareUrl;

  /// Changelog entries between versions.
  final String changelog;

  Map<String, dynamic> toJson() => {
    'current_version': currentVersion,
    'latest_version': latestVersion,
    'needs_update': needsUpdate,
    'template_repo': templateRepo,
    'release_url': releaseUrl,
    'compare_url': compareUrl,
    'changelog': changelog,
  };
}

/// Reads the copier answers file and extracts template metadata.
///
/// Returns a map with `_commit` (current version) and `_src_path` (template URL).
Map<String, String> readCopierAnswers() {
  final packageDir = getPackageDir();
  final file = File('${packageDir.path}/$_copierAnswersFile');

  if (!file.existsSync()) {
    throw Exception(
      '$_copierAnswersFile not found at: ${file.path}\n'
      'This project does not appear to be a copier template consumer.',
    );
  }

  final content = file.readAsStringSync();

  final commitMatch = RegExp(r'_commit:\s*(.+)').firstMatch(content);
  final srcMatch = RegExp(r'_src_path:\s*(.+)').firstMatch(content);

  if (commitMatch == null) {
    throw Exception('_commit not found in $_copierAnswersFile');
  }
  if (srcMatch == null) {
    throw Exception('_src_path not found in $_copierAnswersFile');
  }

  return {
    '_commit': commitMatch.group(1)!.trim(),
    '_src_path': srcMatch.group(1)!.trim(),
  };
}

/// Extracts GitHub owner/repo from a template URL.
///
/// Handles both HTTPS and SSH URLs:
/// - `https://github.com/owner/repo.git` -> `owner/repo`
/// - `git@github.com:owner/repo.git` -> `owner/repo`
String extractGitHubRepo(String srcPath) {
  final match = RegExp(r'github\.com[/:]([^/]+/[^/.]+)').firstMatch(srcPath);
  if (match == null) {
    throw Exception(
      'Could not extract GitHub owner/repo from: $srcPath\n'
      'Expected a GitHub URL (HTTPS or SSH).',
    );
  }
  return match.group(1)!;
}

/// Checks for template updates.
///
/// If [targetVersion] is provided, checks against that specific version.
/// Otherwise, fetches the latest release from the template repository.
Future<TemplateCheckResult> checkForTemplateUpdates({
  String? targetVersion,
  bool silent = false,
}) async {
  // Read current version from .copier-answers.yml
  final answers = readCopierAnswers();
  final currentVersion = answers['_commit']!;
  final srcPath = answers['_src_path']!;
  final templateRepo = extractGitHubRepo(srcPath);

  if (!silent) {
    logInfo('Template repository: $templateRepo');
    logInfo('Current template version: $currentVersion');
  }

  // Get target version (either specified or fetch latest)
  String latestVersion;
  String releaseUrl;

  if (targetVersion != null) {
    latestVersion = targetVersion;
    releaseUrl = 'https://github.com/$templateRepo/releases/tag/$targetVersion';
    if (!silent) {
      logInfo('Checking against specified version: $latestVersion');
    }
  } else {
    if (!silent) {
      logStep('Fetching latest release from GitHub...');
    }
    final release = await _fetchLatestRelease(templateRepo);
    latestVersion = release['tag_name'] as String;
    releaseUrl =
        release['html_url'] as String? ??
        'https://github.com/$templateRepo/releases';
    if (!silent) {
      logInfo('Latest template version: $latestVersion');
    }
  }

  // Compare versions
  final comparison = compareVersions(currentVersion, latestVersion);
  final needsUpdate = comparison < 0;

  // Build comparison URL
  final compareUrl =
      'https://github.com/$templateRepo/compare/$currentVersion...$latestVersion';

  // Fetch changelog between versions
  var changelog = '';
  if (needsUpdate) {
    try {
      changelog = await _fetchChangelogBetweenVersions(
        templateRepo,
        currentVersion,
        latestVersion,
        silent: silent,
      );
    } catch (e) {
      if (!silent) {
        logWarn('Could not fetch changelog: $e');
      }
    }
  }

  return TemplateCheckResult(
    currentVersion: currentVersion,
    latestVersion: latestVersion,
    needsUpdate: needsUpdate,
    templateRepo: templateRepo,
    releaseUrl: releaseUrl,
    compareUrl: compareUrl,
    changelog: changelog,
  );
}

/// Fetch the latest release from GitHub API.
Future<Map<String, dynamic>> _fetchLatestRelease(String repo) async {
  final client = HttpClient();
  try {
    final url = Uri.parse('https://api.github.com/repos/$repo/releases/latest');
    final request = await client.getUrl(url);
    request.headers.set('Accept', 'application/vnd.github.v3+json');
    request.headers.set('User-Agent', 'copier-template-update-checker');

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      return jsonDecode(body) as Map<String, dynamic>;
    } else {
      throw Exception(
        'Failed to fetch latest release from $repo: ${response.statusCode}',
      );
    }
  } finally {
    client.close();
  }
}

/// Fetches and parses CHANGELOG.md from the template repo to extract
/// entries between [fromVersion] and [toVersion].
Future<String> _fetchChangelogBetweenVersions(
  String repo,
  String fromVersion,
  String toVersion, {
  bool silent = false,
}) async {
  if (!silent) {
    logStep('Fetching changelog from template repository...');
  }

  final client = HttpClient();
  try {
    final url = Uri.parse(
      'https://api.github.com/repos/$repo/contents/CHANGELOG.md',
    );
    final request = await client.getUrl(url);
    request.headers.set('Accept', 'application/vnd.github.raw+json');
    request.headers.set('User-Agent', 'copier-template-update-checker');

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    return _extractChangelogEntries(body, fromVersion, toVersion);
  } finally {
    client.close();
  }
}

/// Extracts changelog entries between two versions from CHANGELOG.md content.
///
/// Looks for version headers like `## [1.6.0]` or `## 1.6.0` or `## [v1.6.0]`
/// and returns all content between fromVersion (exclusive) and toVersion (inclusive).
String _extractChangelogEntries(
  String changelog,
  String fromVersion,
  String toVersion,
) {
  final lines = changelog.split('\n');
  final buffer = StringBuffer();
  var capturing = false;

  // Normalize versions for matching (strip 'v' prefix)
  final fromNorm = _stripPrefix(fromVersion);
  final toNorm = _stripPrefix(toVersion);

  for (final line in lines) {
    // Match version headers: ## [1.6.0], ## 1.6.0, ## [v1.6.0], etc.
    final headerMatch = RegExp(
      r'^##\s+\[?v?(\d+\.\d+\.\d+[^\]]*)\]?',
    ).firstMatch(line);

    if (headerMatch != null) {
      final version = headerMatch.group(1)!;

      // Start capturing at toVersion (inclusive)
      if (_versionsMatch(version, toNorm)) {
        capturing = true;
      }
      // Stop capturing at fromVersion (exclusive)
      else if (_versionsMatch(version, fromNorm)) {
        break;
      }
    }

    if (capturing) {
      buffer.writeln(line);
    }
  }

  return buffer.toString().trim();
}

/// Strip 'v' prefix from version string.
String _stripPrefix(String version) {
  if (version.startsWith('v') || version.startsWith('V')) {
    return version.substring(1);
  }
  return version;
}

/// Check if two version strings match (ignoring 'v' prefix).
bool _versionsMatch(String a, String b) {
  return _stripPrefix(a) == _stripPrefix(b);
}

/// Write outputs to a file (e.g. GitHub Actions GITHUB_OUTPUT).
Future<void> writeTemplateGitHubOutputs({
  required TemplateCheckResult result,
  required String outputPath,
}) async {
  final file = File(outputPath);
  final buffer = StringBuffer()
    ..writeln('current_version=${result.currentVersion}')
    ..writeln('latest_version=${result.latestVersion}')
    ..writeln('needs_update=${result.needsUpdate}')
    ..writeln('template_repo=${result.templateRepo}')
    ..writeln('release_url=${result.releaseUrl}')
    ..writeln('compare_url=${result.compareUrl}');

  // Write changelog as multiline value using heredoc delimiter
  if (result.changelog.isNotEmpty) {
    buffer
      ..writeln('changelog<<CHANGELOG_EOF')
      ..writeln(result.changelog)
      ..writeln('CHANGELOG_EOF');
  } else {
    buffer.writeln('changelog=');
  }

  file.writeAsStringSync(buffer.toString(), mode: FileMode.append);
}

/// Print results as JSON.
void printTemplateJsonOutput({required TemplateCheckResult result}) {
  const encoder = JsonEncoder.withIndent('  ');
  print(encoder.convert(result.toJson()));
}

/// Print template update summary in human-readable format.
void printTemplateUpdateSummary({required TemplateCheckResult result}) {
  print('');
  print('========================================');
  print('  Template Update Check');
  print('========================================');
  print('');
  print('  Template:        ${result.templateRepo}');
  print('  Current version: ${result.currentVersion}');
  print('  Latest version:  ${result.latestVersion}');
  print('');

  if (result.needsUpdate) {
    print('  ${Colors.colorize('Update available!', Colors.green)}');
    print('');
    print('  ${Colors.colorize('Compare:', Colors.cyan)} ${result.compareUrl}');
    print('  ${Colors.colorize('Release:', Colors.cyan)} ${result.releaseUrl}');

    if (result.changelog.isNotEmpty) {
      print('');
      print('  ${Colors.colorize('Changelog:', Colors.cyan)}');
      print('');
      for (final line in result.changelog.split('\n')) {
        print('  $line');
      }
    }

    print('');
    print('  ${Colors.colorize('To update, run:', Colors.cyan)}');
    print('    copier update --trust --vcs-ref=${result.latestVersion}');
  } else {
    print('  ${Colors.colorize('Already up to date', Colors.green)}');
  }
  print('');
}
