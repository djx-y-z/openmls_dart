import 'dart:async';
import 'dart:typed_data';

/// Abstract key-value storage interface for MLS state persistence.
///
/// Implement this with any backend (SQLite, Hive, shared preferences, etc.)
/// to provide persistent storage for MLS groups, key packages, and secrets.
///
/// Keys and values are opaque byte arrays. The key format is internal to
/// OpenMLS and should not be interpreted by the implementation.
abstract class MlsStorage {
  /// Read a value by key. Returns `null` if not found.
  FutureOr<Uint8List?> read(Uint8List key);

  /// Write a key-value pair. Overwrites if key already exists.
  FutureOr<void> write(Uint8List key, Uint8List value);

  /// Delete a key-value pair. No-op if key does not exist.
  FutureOr<void> delete(Uint8List key);
}
