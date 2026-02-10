import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late MlsEngine alice;
  late TestIdentity aliceId;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() async {
    alice = await createTestEngine();
    aliceId = TestIdentity.create('alice');
  });

  group('error handling', () {
    test('process malformed message throws', () async {
      final groupResult = await alice.createGroup(
        config: defaultConfig(),
        signerBytes: aliceId.signerBytes,
        credentialIdentity: aliceId.credentialIdentity,
        signerPublicKey: aliceId.publicKey,
      );

      expect(
        () => alice.processMessage(
          groupIdBytes: groupResult.groupId,
          messageBytes: Uint8List.fromList([0, 1, 2, 3]),
        ),
        throwsA(isA<Object>()),
      );
    });

    test('load non-existent group throws', () async {
      final fakeGroupId = Uint8List.fromList(utf8.encode('no-such-group'));

      expect(
        () => alice.groupIsActive(groupIdBytes: fakeGroupId),
        throwsA(isA<Object>()),
      );
    });

    test('extract group ID from invalid bytes throws', () {
      expect(
        () => mlsMessageExtractGroupId(
          messageBytes: Uint8List.fromList([0xFF, 0xFF]),
        ),
        throwsA(isA<Object>()),
      );
    });

    test('extract epoch from invalid bytes throws', () {
      expect(
        () => mlsMessageExtractEpoch(
          messageBytes: Uint8List.fromList([0xFF, 0xFF]),
        ),
        throwsA(isA<Object>()),
      );
    });

    test('content type from invalid bytes throws', () {
      expect(
        () => mlsMessageContentType(
          messageBytes: Uint8List.fromList([0xFF, 0xFF]),
        ),
        throwsA(isA<Object>()),
      );
    });
  });
}
