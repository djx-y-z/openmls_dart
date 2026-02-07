import 'dart:math';
import 'dart:typed_data';

/// Generate random bytes for testing.
Uint8List randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

/// Create test message bytes from string.
Uint8List testMessage(String content) => Uint8List.fromList(content.codeUnits);
