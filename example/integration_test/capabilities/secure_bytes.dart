import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';

bool _allZero(List<int> bytes) => bytes.every((byte) => byte == 0);

void secureBytesCapabilities() {
  group('SecureBytes', () {
    capability('a copy is zeroed on dispose, and the original is left to '
        'its owner', () async {
      final original = Uint8List.fromList([1, 2, 3, 4]);
      final secure = SecureBytes(original);
      expect(secure.bytes, original);
      expect(secure.length, 4);
      expect(secure.isDisposed, isFalse);

      final held = secure.bytes;
      secure.dispose();
      expect(_allZero(held), isTrue, reason: 'its own copy is zeroed');
      expect(original, [1, 2, 3, 4], reason: 'the original is not its own');
      expect(secure.isDisposed, isTrue);
      expect(secure.length, 0);
      expect(() => secure.bytes, throwsStateError);
      // A second dispose is allowed, and changes nothing.
      secure.dispose();
      expect(secure.isDisposed, isTrue);
    });

    capability('a wrapped list is taken over, and zeroed in place', () async {
      final owned = Uint8List.fromList([9, 8, 7]);
      final secure = SecureBytes.wrap(owned);
      expect(identical(secure.bytes, owned), isTrue, reason: 'no copy');

      secure.dispose();
      expect(_allZero(owned), isTrue);
    });

    capability('a list of ints is copied in', () async {
      final ints = [5, 6, 7];
      final secure = SecureBytes.fromList(ints);
      expect(secure.bytes, ints);
      secure.dispose();
      expect(ints, [5, 6, 7]);
    });

    capability('any byte list can be zeroed in place', () async {
      final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
      key.zeroize();
      expect(key, hasLength(32));
      expect(_allZero(key), isTrue);
    });
  });
}
