import 'dart:typed_data';

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

    test('schema_version returns expected value', () async {
      final engine = await createTestEngine();
      expect(engine.schemaVersion(), 1);
    });
  });

  group('engine close / isClosed', () {
    /// Matcher: thrown error message contains "MlsEngine is closed".
    final throwsClosed = throwsA(
      predicate<Object>((e) => e.toString().contains('MlsEngine is closed')),
    );

    test('new engine is not closed', () async {
      final engine = await createTestEngine();
      expect(engine.isClosed(), isFalse);
    });

    test('close sets isClosed to true', () async {
      final engine = await createTestEngine();
      await engine.close();
      expect(engine.isClosed(), isTrue);
    });

    test('close is idempotent', () async {
      final engine = await createTestEngine();
      await engine.close();
      await engine.close(); // second close should not throw
      expect(engine.isClosed(), isTrue);
    });

    test('operations fail after close with specific error', () async {
      final engine = await createTestEngine();
      await engine.close();

      final id = TestIdentity.create('after-close');

      expect(
        () => engine.groupIsActive(groupIdBytes: Uint8List.fromList([1, 2])),
        throwsClosed,
      );
      expect(
        () => engine.createGroup(
          config: defaultConfig(),
          signerBytes: id.signerBytes,
          credentialIdentity: id.credentialIdentity,
          signerPublicKey: id.publicKey,
        ),
        throwsClosed,
      );
      expect(
        () => engine.createKeyPackage(
          ciphersuite: ciphersuite,
          signerBytes: id.signerBytes,
          credentialIdentity: id.credentialIdentity,
          signerPublicKey: id.publicKey,
        ),
        throwsClosed,
      );
    });

    test('close after creating a group', () async {
      final engine = await createTestEngine();
      final id = TestIdentity.create('close-with-state');

      // Create a group so the engine has state
      final result = await engine.createGroup(
        config: defaultConfig(),
        signerBytes: id.signerBytes,
        credentialIdentity: id.credentialIdentity,
        signerPublicKey: id.publicKey,
      );
      expect(await engine.groupIsActive(groupIdBytes: result.groupId), isTrue);

      // Close the engine
      await engine.close();
      expect(engine.isClosed(), isTrue);

      // All operations on the group fail
      expect(
        () => engine.groupIsActive(groupIdBytes: result.groupId),
        throwsClosed,
      );
      expect(
        () => engine.groupEpoch(groupIdBytes: result.groupId),
        throwsClosed,
      );
      expect(
        () => engine.groupMembers(groupIdBytes: result.groupId),
        throwsClosed,
      );
    });

    test('read operations fail after close', () async {
      final engine = await createTestEngine();
      await engine.close();

      final fakeGroupId = Uint8List.fromList([1, 2, 3]);

      expect(() => engine.groupEpoch(groupIdBytes: fakeGroupId), throwsClosed);
      expect(
        () => engine.groupMembers(groupIdBytes: fakeGroupId),
        throwsClosed,
      );
      expect(
        () => engine.groupCiphersuite(groupIdBytes: fakeGroupId),
        throwsClosed,
      );
      expect(
        () => engine.exportRatchetTree(groupIdBytes: fakeGroupId),
        throwsClosed,
      );
    });

    test('write operations fail after close', () async {
      final engine = await createTestEngine();
      final id = TestIdentity.create('write-after-close');
      await engine.close();

      expect(
        () => engine.deleteGroup(groupIdBytes: Uint8List.fromList([1, 2])),
        throwsClosed,
      );
      expect(
        () => engine.deleteKeyPackage(
          keyPackageRefBytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsClosed,
      );
      expect(
        () => engine.selfUpdate(
          groupIdBytes: Uint8List.fromList([1, 2]),
          signerBytes: id.signerBytes,
        ),
        throwsClosed,
      );
    });

    test('new engine works after closing another', () async {
      final engine1 = await createTestEngine();
      final id1 = TestIdentity.create('engine1');

      // Use engine1
      await engine1.createGroup(
        config: defaultConfig(),
        signerBytes: id1.signerBytes,
        credentialIdentity: id1.credentialIdentity,
        signerPublicKey: id1.publicKey,
      );

      // Close engine1
      await engine1.close();
      expect(engine1.isClosed(), isTrue);

      // Create a fresh engine — should work fine
      final engine2 = await createTestEngine();
      expect(engine2.isClosed(), isFalse);
      final id2 = TestIdentity.create('engine2');
      final result = await engine2.createGroup(
        config: defaultConfig(),
        signerBytes: id2.signerBytes,
        credentialIdentity: id2.credentialIdentity,
        signerPublicKey: id2.publicKey,
      );
      expect(result.groupId, isNotEmpty);
    });

    test('closing one engine does not affect another', () async {
      final engine1 = await createTestEngine();
      final engine2 = await createTestEngine();

      final id1 = TestIdentity.create('iso-close-1');
      final id2 = TestIdentity.create('iso-close-2');

      await engine1.createGroup(
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

      // Close engine1
      await engine1.close();
      expect(engine1.isClosed(), isTrue);

      // Engine2 is unaffected
      expect(engine2.isClosed(), isFalse);
      expect(
        await engine2.groupIsActive(groupIdBytes: result2.groupId),
        isTrue,
      );
      expect(
        await engine2.groupEpoch(groupIdBytes: result2.groupId),
        BigInt.zero,
      );
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
