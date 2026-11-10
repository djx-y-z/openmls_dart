import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

void credentialCapabilities() {
  group('credentials', () {
    capability('a basic credential carries its identity there and '
        'back', () async {
      final credential = MlsCredential.basic(identity: bytesOf('alice'));
      expect(credential.credentialType(), 1, reason: 'basic (RFC 9420 §5.3)');
      expect(textOf(credential.identity()), 'alice');
      expect(credential.serializedContent(), bytesOf('alice'));

      final back = MlsCredential.deserialize(bytes: credential.serialize());
      expect(back.credentialType(), 1);
      expect(textOf(back.identity()), 'alice');
      expect(back.serialize(), credential.serialize());

      // A basic credential has no certificates to give.
      expect(credential.certificates, throwsA(anything));
    });

    capability('an X.509 credential carries its chain there and '
        'back', () async {
      final leaf = Uint8List.fromList([0x30, 0x82, 0x01, 0x22, 1, 2, 3]);
      final intermediate = Uint8List.fromList([0x30, 0x82, 0x01, 0x33, 4, 5]);
      final credential = MlsCredential.x509(
        certificateChain: [leaf, intermediate],
      );
      expect(credential.credentialType(), 2, reason: 'x509 (RFC 9420 §5.3)');
      expect(credential.certificates(), [leaf, intermediate]);
      expect(credential.serializedContent(), isNotEmpty);

      final back = MlsCredential.deserialize(bytes: credential.serialize());
      expect(back.credentialType(), 2);
      expect(back.certificates(), [leaf, intermediate]);
      expect(back.serializedContent(), credential.serializedContent());

      // An X.509 credential has no bare identity to give.
      expect(credential.identity, throwsA(anything));
    });

    capability('bytes that are no credential are refused', () async {
      expect(
        () => MlsCredential.deserialize(bytes: Uint8List.fromList([0xff])),
        throwsA(anything),
      );
    });

    capability('a group shows each member by the credential it joined '
        'with', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);

      final own = await bob.engine.groupCredential(groupIdBytes: group);
      expect(textOf(MlsCredential.deserialize(bytes: own).identity()), 'bob');

      final members = await alice.engine.groupMembers(groupIdBytes: group);
      expect(
        [
          for (final member in members)
            textOf(
              MlsCredential.deserialize(bytes: member.credential).identity(),
            ),
        ],
        ['alice', 'bob'],
      );
    });
  });
}
