import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await Openmls.init();
  });

  group('InMemoryMlsStorage utilities', () {
    test('isEmpty, isNotEmpty, and clear', () async {
      final storage = InMemoryMlsStorage();
      expect(storage.isEmpty, isTrue);
      expect(storage.isNotEmpty, isFalse);

      // Create a group to populate storage
      final client = MlsClient(storage);
      final id = TestIdentity.create('util-test');
      await client.createGroup(
        config: defaultConfig(),
        signerBytes: id.signerBytes,
        credentialIdentity: id.credentialIdentity,
        signerPublicKey: id.publicKey,
      );

      expect(storage.isEmpty, isFalse);
      expect(storage.isNotEmpty, isTrue);

      storage.clear();
      expect(storage.isEmpty, isTrue);
      expect(storage.length, equals(0));
    });
  });

  group('storage isolation', () {
    test('separate storage instances are independent', () async {
      final storage1 = InMemoryMlsStorage();
      final storage2 = InMemoryMlsStorage();
      final client1 = MlsClient(storage1);
      final client2 = MlsClient(storage2);

      final id1 = TestIdentity.create('user1');
      final id2 = TestIdentity.create('user2');

      await client1.createGroup(
        config: defaultConfig(),
        signerBytes: id1.signerBytes,
        credentialIdentity: id1.credentialIdentity,
        signerPublicKey: id1.publicKey,
      );

      await client2.createGroup(
        config: defaultConfig(),
        signerBytes: id2.signerBytes,
        credentialIdentity: id2.credentialIdentity,
        signerPublicKey: id2.publicKey,
      );

      // Both storages have data but are independent
      expect(storage1.length, greaterThan(0));
      expect(storage2.length, greaterThan(0));
    });
  });
}
