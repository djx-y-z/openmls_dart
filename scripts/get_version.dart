#!/usr/bin/env dart

/// Get version information from rust/Cargo.toml and pubspec.yaml.
///
/// Usage:
///   dart scripts/get_version.dart [--field <field>]
///
/// Options:
///   --field version  - Print only crate version
///   --field package  - Print package version
///
/// Without --field, prints all version information.
library;

import 'dart:io';

import 'src/common.dart';

void main(List<String> args) async {
  final field = _parseField(args);
  final packageDir = getPackageDir();

  final crateVersion = await _readCrateVersion(packageDir);
  final packageVersion = await _readPackageVersion(packageDir);

  switch (field) {
    case 'version':
      print(crateVersion);
    case 'package':
      print(packageVersion);
    default:
      print('openmls Version Information:');
      print('  Package version: $packageVersion');
      print('  Crate version:   $crateVersion');
  }
}

String? _parseField(List<String> args) {
  final index = args.indexOf('--field');
  if (index != -1 && index + 1 < args.length) {
    return args[index + 1];
  }
  return null;
}

/// Reads the crate version from rust/Cargo.toml.
Future<String> _readCrateVersion(Directory packageDir) async {
  final cargoFile = File('${packageDir.path}/rust/Cargo.toml');
  if (!cargoFile.existsSync()) {
    return '0.0.0';
  }

  final content = await cargoFile.readAsString();
  final versionMatch = RegExp(
    r'^version\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(content);

  return versionMatch?.group(1)?.trim() ?? '0.0.0';
}

Future<String> _readPackageVersion(Directory packageDir) async {
  final pubspecFile = File('${packageDir.path}/pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    return '0.0.0';
  }

  final content = await pubspecFile.readAsString();
  final versionMatch = RegExp(
    r'^version:\s*(.+)$',
    multiLine: true,
  ).firstMatch(content);

  return versionMatch?.group(1)?.trim() ?? '0.0.0';
}
