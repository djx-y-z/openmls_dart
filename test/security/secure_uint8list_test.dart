// ignore_for_file: cascade_invocations
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

void main() {
  group('SecureUint8List extension', () {
    test('zeroize zeros all bytes', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 255, 128, 64]);

      data.zeroize();

      expect(data, equals([0, 0, 0, 0, 0, 0, 0, 0]));
      expect(data.length, equals(8)); // Length unchanged
    });

    test('zeroize on empty list does nothing', () {
      final data = Uint8List(0);

      data.zeroize();

      expect(data, isEmpty);
    });

    test('zeroize on single element', () {
      final data = Uint8List.fromList([42]);

      data.zeroize();

      expect(data, equals([0]));
    });

    test('zeroize on large buffer', () {
      final data = Uint8List(1000);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      data.zeroize();

      expect(data.every((b) => b == 0), isTrue);
    });
  });
}
