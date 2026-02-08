import 'dart:typed_data';

/// Extension for zeroing sensitive Uint8List data.
extension SecureUint8List on Uint8List {
  /// Zero out all bytes in this list.
  ///
  /// **Important:** This does not guarantee the data is removed from memory
  /// due to Dart's garbage collector potentially having made copies.
  /// Use for defence-in-depth, not as a security guarantee.
  void zeroize() => fillRange(0, length, 0);
}
