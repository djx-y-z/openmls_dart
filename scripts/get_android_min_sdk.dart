import 'dart:io';

/// Reads Android minSdk from android/build.gradle file.
///
/// Usage: dart scripts/get_android_min_sdk.dart
void main() {
  final file = File('android/build.gradle');
  if (!file.existsSync()) {
    stderr.writeln('Error: android/build.gradle not found');
    exit(1);
  }

  final content = file.readAsStringSync();
  final match = RegExp(r'minSdk\s*=\s*(\d+)').firstMatch(content);

  if (match == null) {
    stderr.writeln('Error: minSdk not found in android/build.gradle');
    exit(1);
  }

  print(match.group(1));
}
