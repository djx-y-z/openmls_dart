// ignore_for_file: cascade_invocations
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

void main() {
  // NOTE: Finalizer behavior is not tested here because:
  // 1. Dart's GC is non-deterministic - we cannot reliably trigger finalization
  // 2. Forcing GC (if possible) would make tests slow and flaky
  // 3. The finalizer is a backup mechanism; explicit dispose() is the primary path
  // 4. The finalizer code is trivial (single fillRange call) and covered by dispose() tests
  // The important guarantee is that dispose() works correctly, which IS tested below.
  group('SecureBytes', () {
    test('creates copy from Uint8List', () {
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final secure = SecureBytes(original);

      // Should be a copy, not the same reference
      expect(secure.bytes, isNot(same(original)));
      expect(secure.bytes, equals([1, 2, 3, 4, 5]));
      expect(secure.length, equals(5));
      expect(secure.isDisposed, isFalse);
    });

    test('creates from list of integers', () {
      final secure = SecureBytes.fromList([10, 20, 30]);

      expect(secure.bytes, equals([10, 20, 30]));
      expect(secure.length, equals(3));
    });

    test('wrap takes ownership without copying', () {
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final secure = SecureBytes.wrap(original);

      // Should be the same reference (no copy)
      expect(secure.bytes, same(original));
      expect(secure.length, equals(5));
    });

    test('dispose zeros the data', () {
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final secure = SecureBytes.wrap(original);

      secure.dispose();

      // After dispose, original data should be zeroed
      expect(original, equals([0, 0, 0, 0, 0]));
      expect(secure.isDisposed, isTrue);
      expect(secure.length, equals(0));
    });

    test('dispose can be called multiple times safely', () {
      final secure = SecureBytes.fromList([1, 2, 3]);

      secure.dispose();
      expect(secure.isDisposed, isTrue);

      // Should not throw
      secure.dispose();
      secure.dispose();
      expect(secure.isDisposed, isTrue);
    });

    test('accessing bytes after dispose throws StateError', () {
      final secure = SecureBytes.fromList([1, 2, 3]);
      secure.dispose();

      expect(() => secure.bytes, throwsStateError);
    });

    test('copy constructor does not zero original', () {
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final secure = SecureBytes(original);

      secure.dispose();

      // Original should NOT be zeroed (copy constructor)
      expect(original, equals([1, 2, 3, 4, 5]));
      expect(secure.isDisposed, isTrue);
    });

    test('handles empty data', () {
      final secure = SecureBytes.fromList([]);

      expect(secure.bytes, isEmpty);
      expect(secure.length, equals(0));

      secure.dispose();
      expect(secure.isDisposed, isTrue);
    });
  });
}
