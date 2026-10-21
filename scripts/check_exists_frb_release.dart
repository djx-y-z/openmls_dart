#!/usr/bin/env dart

/// Check if a FRB release already exists on GitHub.
///
/// Usage:
///   dart scripts/check_exists_frb_release.dart [--ci]
///
/// Options:
///   --ci  Output in CI-friendly format (GitHub Actions outputs)
///
/// This script checks if the current crate version already has a release.
/// Used by CI to determine if a new build is needed.
///
/// CI Outputs:
///   - version: The crate version from rust/Cargo.toml

///   - openmls_version: The upstream openmls version

///   - skip: 'true' if release exists, 'false' otherwise
library;

import 'dart:io';

import 'src/common.dart';
import 'src/upstream_source.dart';

void main(List<String> args) async {
  final isCi = args.contains('--ci');

  final version = getCrateVersion();

  final upstreamVersion = getUpstreamVersion();

  final releaseTag = 'openmls_frb-$version';

  logInfo('Checking release status...');
  logInfo('Crate version: $version');

  logInfo('openmls version: $upstreamVersion');

  logInfo('Release tag: $releaseTag');

  // Check if release already exists on GitHub. Fail closed: if we cannot tell
  // (no token, unexpected status, network error), abort rather than reporting
  // skip=false, which would let a build proceed on a wrong assumption.
  final status = await _checkReleaseExists(releaseTag);
  if (status == _ReleaseStatus.inconclusive) {
    logError(
      'Could not determine whether $releaseTag exists (GitHub API error, '
      'missing token, or network failure). Aborting instead of guessing. '
      'Re-run the workflow, or verify the release manually.',
    );
    exit(1);
  }
  final releaseExists = status == _ReleaseStatus.exists;

  if (isCi) {
    // Output for GitHub Actions
    final outputFile = Platform.environment['GITHUB_OUTPUT'];
    if (outputFile != null) {
      final file = File(outputFile);
      final buffer = StringBuffer()
        ..writeln('version=$version')
        ..writeln('openmls_version=$upstreamVersion')
        ..writeln('skip=${releaseExists ? 'true' : 'false'}');
      file.writeAsStringSync(buffer.toString(), mode: FileMode.append);
    }

    if (releaseExists) {
      logWarn('Release $releaseTag already exists. Skipping build.');
    } else {
      logInfo('Release $releaseTag does not exist. Build will proceed.');
    }
  } else {
    if (releaseExists) {
      logWarn('Release $releaseTag already exists on GitHub.');
    } else {
      logInfo('Release $releaseTag does not exist. Ready to build.');
    }
  }
}

/// Three-state result of the release-existence probe. `inconclusive` (no token,
/// unexpected status, network error) is treated as fail-closed by the caller.
enum _ReleaseStatus { exists, missing, inconclusive }

Future<_ReleaseStatus> _checkReleaseExists(String tag) async {
  final token = Platform.environment['GITHUB_TOKEN'];
  if (token == null || token.isEmpty) {
    logWarn('GITHUB_TOKEN not set. Cannot check release status.');
    return _ReleaseStatus.inconclusive;
  }

  final client = HttpClient();
  try {
    final url = Uri.parse(
      'https://api.github.com/repos/djx-y-z/openmls_dart/releases/tags/$tag',
    );
    final request = await client.getUrl(url);
    request.headers.set('Authorization', 'token $token');
    request.headers.set('Accept', 'application/vnd.github.v3+json');
    request.headers.set('User-Agent', 'openmls-build-script');

    final response = await request.close();
    await response.drain<void>();

    if (response.statusCode == 200) {
      return _ReleaseStatus.exists;
    } else if (response.statusCode == 404) {
      return _ReleaseStatus.missing;
    } else {
      logWarn('Unexpected response from GitHub API: ${response.statusCode}');
      return _ReleaseStatus.inconclusive;
    }
  } catch (e) {
    logWarn('Failed to check release: $e');
    return _ReleaseStatus.inconclusive;
  } finally {
    client.close();
  }
}
