import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

/// Extract the identity string from a TLS-serialized Credential.
String credentialName(List<int> credentialBytes) => utf8.decode(
  MlsCredential.deserialize(
    bytes: Uint8List.fromList(credentialBytes),
  ).identity(),
);

/// Convert bytes to hex string, optionally truncating with "...".
String bytesToHex(Uint8List bytes, {int? maxLength}) {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  if (maxLength != null && hex.length > maxLength) {
    return '${hex.substring(0, maxLength)}...';
  }
  return hex;
}

/// Print a section header.
void printHeader(String title) {
  print('');
  print('${'═' * 3} $title ${'═' * 3}');
  print('');
}

/// Print a numbered step with optional indented details.
void printStep(int number, String description, [List<String>? details]) {
  print('$number. $description');
  if (details != null) {
    for (final detail in details) {
      print('   $detail');
    }
  }
}
