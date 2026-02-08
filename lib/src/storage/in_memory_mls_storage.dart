import 'dart:convert';
import 'dart:typed_data';

import 'mls_storage.dart';

/// In-memory implementation of [MlsStorage] backed by a [Map].
///
/// Useful for testing, prototyping, and simple applications that don't need
/// persistent storage. All data is lost when the instance is garbage collected.
///
/// For production use, implement [MlsStorage] with a persistent backend
/// such as SQLite, Hive, or shared preferences.
///
/// ```dart
/// final storage = InMemoryMlsStorage();
/// final client = MlsClient(storage);
///
/// final result = await client.createGroup(
///   config: config,
///   signerBytes: signer,
///   credentialIdentity: identity,
///   signerPublicKey: pubKey,
/// );
/// ```
class InMemoryMlsStorage implements MlsStorage {
  final Map<String, Uint8List> _store = {};

  String _key(Uint8List k) => base64Encode(k);

  @override
  Uint8List? read(Uint8List key) => _store[_key(key)];

  @override
  void write(Uint8List key, Uint8List value) => _store[_key(key)] = value;

  @override
  void delete(Uint8List key) => _store.remove(_key(key));

  /// The number of entries currently stored.
  int get length => _store.length;

  /// Whether the storage is empty.
  bool get isEmpty => _store.isEmpty;

  /// Whether the storage is not empty.
  bool get isNotEmpty => _store.isNotEmpty;

  /// Removes all entries from the storage.
  void clear() => _store.clear();
}
