#!/usr/bin/env dart

/// Check platform deployment target consistency across all project files.
///
/// Reads expected versions from `.copier-answers.yml` and verifies all
/// locations where deployment targets are set match the source of truth.
///
/// Usage:
///   fvm dart run scripts/check_deployment_targets.dart [options]
///
/// Options:
///   - `--ios`             Check iOS only
///   - `--macos`           Check macOS only
///   - `--android`         Check Android only
///   - `--all`             Check all platforms (default)
///   - `--update`          Fix mismatches in-place
///   - `--set <version>`   Set a new version (requires exactly one platform flag)
///   - `--help, -h`        Show this help
///
/// Exit codes:
///   0 - All files match
///   1 - Mismatch found (use --update to fix)
///   2 - Error occurred
library;

import 'dart:io';

import 'src/common.dart';

// =============================================================================
// Platform definitions
// =============================================================================

enum Platform {
  ios('ios_min_version', 'iOS'),
  macos('macos_min_version', 'macOS'),
  android('android_min_sdk', 'Android');

  const Platform(this.copierKey, this.displayName);

  final String copierKey;
  final String displayName;
}

// =============================================================================
// Entry point
// =============================================================================

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }

  // Parse platform flags
  final hasIos = args.contains('--ios');
  final hasMacos = args.contains('--macos');
  final hasAndroid = args.contains('--android');
  final hasAll = args.contains('--all');
  final doUpdate = args.contains('--update');

  // Parse --set <version>
  String? setVersion;
  final setIndex = args.indexOf('--set');
  if (setIndex != -1) {
    if (setIndex + 1 >= args.length) {
      logError('--set requires a version argument (e.g. --set 14.0)');
      exit(2);
    }
    setVersion = args[setIndex + 1];
  }

  // Determine which platforms to check
  final selectedPlatforms = <Platform>[];
  if (hasIos) selectedPlatforms.add(Platform.ios);
  if (hasMacos) selectedPlatforms.add(Platform.macos);
  if (hasAndroid) selectedPlatforms.add(Platform.android);

  // Default to all if none specified
  if (selectedPlatforms.isEmpty || hasAll) {
    selectedPlatforms
      ..clear()
      ..addAll(Platform.values);
  }

  // --set requires exactly one platform
  if (setVersion != null && selectedPlatforms.length != 1) {
    logError(
      '--set requires exactly one platform flag (--ios, --macos, or --android)',
    );
    exit(2);
  }

  // Validate --set format per platform
  if (setVersion != null) {
    final platform = selectedPlatforms.first;
    if (platform == Platform.android) {
      if (int.tryParse(setVersion) == null) {
        logError(
          'Invalid Android SDK version: $setVersion (expected integer, e.g. 24)',
        );
        exit(2);
      }
    } else {
      if (!RegExp(r'^\d+\.\d+$').hasMatch(setVersion)) {
        logError(
          'Invalid ${platform.displayName} version: $setVersion (expected X.Y, e.g. 13.0)',
        );
        exit(2);
      }
    }
  }

  print('');
  print('========================================');
  print('  Deployment Target Checker');
  print('========================================');
  print('');

  try {
    final packageDir = getPackageDir();

    // --set: update source of truth first
    if (setVersion != null) {
      final platform = selectedPlatforms.first;
      final current = _readCopierValue(packageDir, platform.copierKey);
      if (current == setVersion) {
        logInfo('${platform.displayName} version is already $setVersion');
      } else {
        _writeCopierValue(packageDir, platform.copierKey, setVersion);
        logSuccess(
          'Updated .copier-answers.yml ${platform.copierKey}: $current -> $setVersion',
        );
      }
      print('');
    }

    var totalChecks = 0;
    final allMismatches = <_CheckResult>[];

    for (final platform in selectedPlatforms) {
      final expected = _readCopierValue(packageDir, platform.copierKey);
      logInfo('${platform.displayName} expected: $expected');

      final checks = _buildChecks(platform, expected);
      totalChecks += checks.length;

      for (final check in checks) {
        final result = _checkFile(check, expected);
        if (!result.ok) {
          allMismatches.add(result);
        }
      }
    }

    print('');

    if (allMismatches.isEmpty) {
      logSuccess(
        'All $totalChecks locations match across ${selectedPlatforms.length} platform(s)',
      );
      exit(0);
    }

    logWarn('Found ${allMismatches.length} mismatch(es):');
    print('');

    for (final m in allMismatches) {
      logError(
        '  ${m.check.label}: expected ${m.expectedVersion}, found ${m.foundVersion}',
      );
      logInfo('    File: ${m.check.relativePath}');
    }

    if (doUpdate || setVersion != null) {
      print('');
      logStep('Updating mismatched files...');
      for (final m in allMismatches) {
        _updateFile(m.check, m.expectedVersion);
        logSuccess('  Updated ${m.check.relativePath}');
      }
      print('');
      logSuccess('All files updated');
      exit(0);
    } else {
      print('');
      logInfo('Run with --update to fix mismatches automatically.');
      exit(1);
    }
  } catch (e) {
    logError('$e');
    exit(2);
  }
}

// =============================================================================
// Source of truth (.copier-answers.yml)
// =============================================================================

String _readCopierValue(Directory packageDir, String key) {
  final file = File('${packageDir.path}/.copier-answers.yml');
  if (!file.existsSync()) {
    throw Exception('.copier-answers.yml not found');
  }

  final content = file.readAsStringSync();
  final match = RegExp(
    "^$key:\\s*'([^']+)'",
    multiLine: true,
  ).firstMatch(content);

  if (match == null) {
    throw Exception('$key not found in .copier-answers.yml');
  }

  return match.group(1)!;
}

void _writeCopierValue(Directory packageDir, String key, String value) {
  final file = File('${packageDir.path}/.copier-answers.yml');
  final content = file.readAsStringSync();
  final pattern = RegExp("^($key:\\s*')([^']+)(')", multiLine: true);

  if (!pattern.hasMatch(content)) {
    throw Exception('$key not found in .copier-answers.yml');
  }

  file.writeAsStringSync(
    content.replaceFirstMapped(pattern, (m) => '${m[1]}$value${m[3]}'),
  );
}

// =============================================================================
// Check definitions
// =============================================================================

class _FileCheck {
  _FileCheck({
    required this.label,
    required this.relativePath,
    required this.pattern,
    required this.replacement,
    this.versionGroup = 1,
  });

  final String label;
  final String relativePath;

  /// Regex with a capture group for the version number.
  final RegExp pattern;

  /// Function that produces the replacement string with the expected version.
  /// May contain `${N}` placeholders for backreferences to other capture groups.
  final String Function(String expectedVersion) replacement;

  /// Which capture group contains the version number (1-based).
  final int versionGroup;
}

class _CheckResult {
  _CheckResult({
    required this.check,
    required this.ok,
    required this.expectedVersion,
    this.foundVersion,
  });

  final _FileCheck check;
  final bool ok;
  final String expectedVersion;
  final String? foundVersion;
}

List<_FileCheck> _buildChecks(Platform platform, String expected) {
  return switch (platform) {
    Platform.ios => _buildIosChecks(expected),
    Platform.macos => _buildMacosChecks(),
    Platform.android => _buildAndroidChecks(expected),
  };
}

List<_FileCheck> _buildIosChecks(String expected) {
  return [
    _FileCheck(
      label: 'iOS podspec',
      relativePath: 'ios/openmls.podspec',
      pattern: RegExp(r"s\.platform\s*=\s*:ios,\s*'([^']+)'"),
      replacement: (v) => "s.platform = :ios, '$v'",
    ),
    _FileCheck(
      label: 'iOS CI workflow',
      relativePath: '.github/workflows/build-openmls.yml',
      pattern: RegExp(r"IPHONEOS_DEPLOYMENT_TARGET:\s*'([^']+)'"),
      replacement: (v) => "IPHONEOS_DEPLOYMENT_TARGET: '$v'",
    ),
    _FileCheck(
      label: 'iOS Xcode project',
      relativePath: 'example/ios/Runner.xcodeproj/project.pbxproj',
      pattern: RegExp(r'IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([0-9.]+)\s*;'),
      replacement: (v) => 'IPHONEOS_DEPLOYMENT_TARGET = $v;',
    ),
    _FileCheck(
      label: 'iOS AppFrameworkInfo.plist',
      relativePath: 'example/ios/Flutter/AppFrameworkInfo.plist',
      pattern: RegExp(
        r'<key>MinimumOSVersion</key>\s*\n\s*<string>([^<]+)</string>',
      ),
      replacement: (v) => '<key>MinimumOSVersion</key>\n  <string>$v</string>',
    ),
    _FileCheck(
      label: 'README iOS version',
      relativePath: 'README.md',
      // Matches: | **Support** | SDK 24+ | 13.0+ | ...
      pattern: RegExp(r'(\| \*\*Support\*\* \| SDK \d+\+\s*\| )([0-9.]+)\+'),
      replacement: (v) => '\${1}$v+',
      versionGroup: 2,
    ),
  ];
}

List<_FileCheck> _buildMacosChecks() {
  return [
    _FileCheck(
      label: 'macOS podspec',
      relativePath: 'macos/openmls.podspec',
      pattern: RegExp(r"s\.platform\s*=\s*:osx,\s*'([^']+)'"),
      replacement: (v) => "s.platform = :osx, '$v'",
    ),
    _FileCheck(
      label: 'macOS Xcode project',
      relativePath: 'example/macos/Runner.xcodeproj/project.pbxproj',
      pattern: RegExp(r'MACOSX_DEPLOYMENT_TARGET\s*=\s*([0-9.]+)\s*;'),
      replacement: (v) => 'MACOSX_DEPLOYMENT_TARGET = $v;',
    ),
    _FileCheck(
      label: 'README macOS version',
      relativePath: 'README.md',
      // Matches: | 13.0+ | 10.15+ | arm64, x64 |
      pattern: RegExp(
        r'(\| [0-9.]+\+\s*\| )([0-9.]+)\+(\s*\| arm64, x64\s*\|)',
      ),
      replacement: (v) => '\${1}$v+\${3}',
      versionGroup: 2,
    ),
  ];
}

List<_FileCheck> _buildAndroidChecks(String expected) {
  return [
    _FileCheck(
      label: 'Android build.gradle',
      relativePath: 'android/build.gradle',
      pattern: RegExp(r'minSdk\s*=\s*(\d+)'),
      replacement: (v) => 'minSdk = $v',
    ),
    _FileCheck(
      label: 'README Android version',
      relativePath: 'README.md',
      // Matches: | **Support** | SDK 24+ |
      pattern: RegExp(r'(\| \*\*Support\*\* \| SDK )(\d+)\+'),
      replacement: (v) => '\${1}$v+',
      versionGroup: 2,
    ),
  ];
}

// =============================================================================
// Check & update logic
// =============================================================================

_CheckResult _checkFile(_FileCheck check, String expected) {
  final packageDir = getPackageDir();
  final file = File('${packageDir.path}/${check.relativePath}');

  if (!file.existsSync()) {
    logWarn('File not found: ${check.relativePath} (skipped)');
    return _CheckResult(check: check, ok: true, expectedVersion: expected);
  }

  final content = file.readAsStringSync();
  final matches = check.pattern.allMatches(content).toList();

  if (matches.isEmpty) {
    logWarn('Pattern not found in ${check.relativePath} (skipped)');
    return _CheckResult(check: check, ok: true, expectedVersion: expected);
  }

  for (final match in matches) {
    final found = match.group(check.versionGroup)!;
    if (found != expected) {
      logError('[MISMATCH] ${check.label}: $found (expected $expected)');
      return _CheckResult(
        check: check,
        ok: false,
        expectedVersion: expected,
        foundVersion: found,
      );
    }
  }

  final count = matches.length;
  final suffix = count > 1 ? ' ($count occurrences)' : '';
  logSuccess('[OK] ${check.label}$suffix');
  return _CheckResult(check: check, ok: true, expectedVersion: expected);
}

void _updateFile(_FileCheck check, String expected) {
  final packageDir = getPackageDir();
  final file = File('${packageDir.path}/${check.relativePath}');
  var content = file.readAsStringSync();

  content = content.replaceAllMapped(check.pattern, (match) {
    // Build the replacement by substituting the version in the template
    var result = check.replacement(expected);
    // Replace backreference placeholders ${N} with actual match groups
    for (var i = 0; i <= match.groupCount; i++) {
      result = result.replaceAll('\${$i}', match.group(i) ?? '');
    }
    return result;
  });

  file.writeAsStringSync(content);
}

// =============================================================================
// Usage
// =============================================================================

void _printUsage() {
  print('''
Deployment Target Checker

Reads expected versions from .copier-answers.yml and checks all project
files for consistency.

Usage:
  fvm dart run scripts/check_deployment_targets.dart [options]

Platform flags:
  --ios       Check iOS deployment target
  --macos     Check macOS deployment target
  --android   Check Android minSdk
  --all       Check all platforms (default)

Options:
  --update        Fix mismatches in-place
  --set <version> Set a new version everywhere (requires one platform flag)
  --help, -h      Show this help

Examples:
  # Check all platforms
  fvm dart run scripts/check_deployment_targets.dart

  # Check iOS only
  fvm dart run scripts/check_deployment_targets.dart --ios

  # Fix all mismatches
  fvm dart run scripts/check_deployment_targets.dart --update

  # Change iOS deployment target to 14.0 everywhere
  fvm dart run scripts/check_deployment_targets.dart --ios --set 14.0

  # Change Android minSdk to 26 everywhere
  fvm dart run scripts/check_deployment_targets.dart --android --set 26

Files checked:
  iOS (ios_min_version):
    1. ios/openmls.podspec
    2. .github/workflows/build-openmls.yml
    3. example/ios/Runner.xcodeproj/project.pbxproj
    4. example/ios/Flutter/AppFrameworkInfo.plist
    5. README.md platform table

  macOS (macos_min_version):
    1. macos/openmls.podspec
    2. example/macos/Runner.xcodeproj/project.pbxproj
    3. README.md platform table

  Android (android_min_sdk):
    1. android/build.gradle
    2. README.md platform table

Exit codes:
  0 - All files match
  1 - Mismatch found (use --update to fix)
  2 - Error occurred
''');
}
