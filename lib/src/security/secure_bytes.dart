import 'dart:typed_data';

/// Wrapper for sensitive byte data with automatic zeroing on finalization.
///
/// **Important limitations:**
/// - Dart GC may copy data before finalizer runs
/// - This is defence-in-depth, not a security guarantee
/// - For maximum security, call [dispose] explicitly when done
///
/// **Thread/Isolate safety:**
/// This class is designed for single-isolate use. The `_disposed` flag is not
/// atomic, but this is not a practical concern because Dart isolates don't share
/// memory. Each isolate should have its own SecureBytes instances.
///
/// **Usage:**
/// ```dart
/// // Copy constructor - original data is NOT zeroed (caller responsible)
/// final secure = SecureBytes(sensitiveBytes);
///
/// // Wrap constructor - takes ownership, original reference should not be used
/// final secure = SecureBytes.wrap(sensitiveBytes);
///
/// // ... use secure.bytes ...
///
/// secure.dispose(); // Explicit zeroing (recommended)
/// ```
class SecureBytes {
  /// Creates a SecureBytes by copying the input data.
  ///
  /// **Note:** The original [data] is NOT zeroed - caller is responsible for it.
  SecureBytes(Uint8List data) : _data = Uint8List.fromList(data) {
    _finalizer.attach(this, _data, detach: this);
  }

  /// Creates SecureBytes from a list of integers (copies data).
  SecureBytes.fromList(List<int> data) : this(Uint8List.fromList(data));

  /// Creates a SecureBytes by taking ownership of the input data.
  ///
  /// The input [data] reference should not be used after this call.
  /// This avoids creating an extra copy.
  factory SecureBytes.wrap(Uint8List data) => SecureBytes._wrap(data);

  SecureBytes._wrap(this._data) {
    _finalizer.attach(this, _data, detach: this);
  }

  static final _finalizer = Finalizer<Uint8List>((list) {
    list.fillRange(0, list.length, 0); // coverage:ignore-line
  });

  final Uint8List _data;
  bool _disposed = false;

  /// Access the underlying bytes.
  ///
  /// Throws [StateError] if already disposed.
  Uint8List get bytes {
    if (_disposed) {
      throw StateError('SecureBytes has been disposed');
    }
    return _data;
  }

  /// The length of the data (0 if disposed).
  int get length => _disposed ? 0 : _data.length;

  /// Whether this instance has been disposed.
  bool get isDisposed => _disposed;

  /// Explicitly zero and dispose the data.
  ///
  /// Call this when you're done with sensitive data for immediate cleanup.
  /// Safe to call multiple times.
  void dispose() {
    if (!_disposed) {
      _data.fillRange(0, _data.length, 0);
      _finalizer.detach(this);
      _disposed = true;
    }
  }
}
