import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

/// Convert bytes to hex string, optionally truncating with "...".
String hex(Uint8List bytes, {int? max}) {
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  if (max != null && h.length > max) return '${h.substring(0, max)}...';
  return h;
}

/// Extract the identity string from a TLS-serialized Credential.
String credName(List<int> credBytes) => utf8.decode(
  MlsCredential.deserialize(bytes: Uint8List.fromList(credBytes)).identity(),
);
