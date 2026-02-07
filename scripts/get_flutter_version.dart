import 'dart:convert';
import 'dart:io';

/// Reads Flutter version from .fvmrc file.
///
/// Usage: dart run scripts/get_flutter_version.dart
void main() {
  final file = File('.fvmrc');
  if (!file.existsSync()) {
    stderr.writeln('Error: .fvmrc not found');
    exit(1);
  }

  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final version = json['flutter'] as String?;

  if (version == null) {
    stderr.writeln('Error: flutter version not found in .fvmrc');
    exit(1);
  }

  print(version);
}
