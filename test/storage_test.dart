import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await Openmls.init();
  });

  group('MlsEngine creation', () {
    test('creates an engine with in-memory database', () async {
      final engine = await createTestEngine();
      // Engine should be usable — create a group to verify
      final id = TestIdentity.create('util-test');
      final result = await engine.createGroup(
        config: defaultConfig(),
        signerBytes: id.signerBytes,
        credentialIdentity: id.credentialIdentity,
        signerPublicKey: id.publicKey,
      );
      expect(result.groupId, isNotEmpty);
    });
  });

  group('engine isolation', () {
    test('separate engine instances are independent', () async {
      final engine1 = await createTestEngine();
      final engine2 = await createTestEngine();

      final id1 = TestIdentity.create('user1');
      final id2 = TestIdentity.create('user2');

      final result1 = await engine1.createGroup(
        config: defaultConfig(),
        signerBytes: id1.signerBytes,
        credentialIdentity: id1.credentialIdentity,
        signerPublicKey: id1.publicKey,
      );

      final result2 = await engine2.createGroup(
        config: defaultConfig(),
        signerBytes: id2.signerBytes,
        credentialIdentity: id2.credentialIdentity,
        signerPublicKey: id2.publicKey,
      );

      // Both engines created groups independently
      expect(result1.groupId, isNotEmpty);
      expect(result2.groupId, isNotEmpty);

      // Each engine only sees its own group
      final active1 = await engine1.groupIsActive(
        groupIdBytes: result1.groupId,
      );
      final active2 = await engine2.groupIsActive(
        groupIdBytes: result2.groupId,
      );
      expect(active1, isTrue);
      expect(active2, isTrue);

      // Engine 1 cannot see engine 2's group
      expect(
        () => engine1.groupIsActive(groupIdBytes: result2.groupId),
        throwsA(isA<Object>()),
      );
    });
  });
}
