import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

void keyCapabilities() {
  group('signature keys', () {
    capability('a key pair signs with the scheme its suite names', () async {
      // The TLS SignatureScheme code points (RFC 8446 §4.2.3) RFC 9420 uses.
      const ed25519 = 0x0807;
      const ecdsaP256 = 0x0403;
      const ecdsaP384 = 0x0503;
      final suites = {
        defaultSuite: ed25519,
        MlsCiphersuite.mls128DhkemP256Aes128GcmSha256P256: ecdsaP256,
        MlsCiphersuite.mls192Mlkem1024Aes256GcmSha384P384: ecdsaP384,
        // The post-quantum suite this package delegates to libcrux still
        // signs with Ed25519: only its KEM is new.
        MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519: ed25519,
      };
      for (final MapEntry(key: suite, value: scheme) in suites.entries) {
        final keys = MlsSignatureKeyPair.generate(ciphersuite: suite);
        expect(keys.signatureScheme(), scheme, reason: '$suite');
      }

      final keys = MlsSignatureKeyPair.generate(ciphersuite: defaultSuite);
      expect(keys.publicKey(), hasLength(32), reason: 'an Ed25519 key');
      expect(
        MlsSignatureKeyPair.generate(ciphersuite: defaultSuite).publicKey(),
        isNot(keys.publicKey()),
        reason: 'every key pair is new',
      );
    });

    capability('the public half travels without the private one', () async {
      final keys = MlsSignatureKeyPair.generate(ciphersuite: defaultSuite);
      final public = MlsSignatureKeyPair.deserializePublic(
        bytes: keys.serialize(),
      );

      expect(public.publicKey(), keys.publicKey());
      expect(public.signatureScheme(), keys.signatureScheme());
      expect(
        _includes(keys.serialize(), keys.privateKey()),
        isFalse,
        reason: 'serialize() carries no private key material',
      );
    });

    capability('a key pair rebuilt from its raw bytes signs as the '
        'original', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final group = await groupOf(alice, [bob]);

      final rebuilt = MlsSignatureKeyPair.fromRaw(
        ciphersuite: defaultSuite,
        privateKey: alice.keys.privateKey(),
        publicKey: alice.keys.publicKey(),
      );
      expect(rebuilt.publicKey(), alice.publicKey);
      expect(rebuilt.privateKey(), alice.keys.privateKey());

      // Signed with the rebuilt pair, and Bob takes it as Alice's.
      final message = await alice.engine.createMessage(
        groupIdBytes: group,
        signerBytes: serializeSigner(
          ciphersuite: defaultSuite,
          privateKey: rebuilt.privateKey(),
          publicKey: rebuilt.publicKey(),
        ),
        message: bytesOf('signed by the rebuilt key'),
      );
      final received = await bob.receive(group, message.ciphertext);
      expect(textOf(received.applicationMessage!), 'signed by the rebuilt key');
      expect(received.senderIndex, 0);
    });

    capability('a member signs with the key it was given', () async {
      final alice = await Party.create('alice');
      final group = await alice.createGroup();

      final leaf = await alice.engine.groupOwnLeafNode(groupIdBytes: group);
      expect(leaf.signatureKey, alice.publicKey);
    });
  });
}

/// Whether [needle] occurs in [haystack] as one run of bytes.
bool _includes(List<int> haystack, List<int> needle) {
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var i = 0;
    while (i < needle.length && haystack[start + i] == needle[i]) {
      i++;
    }
    if (i == needle.length) return true;
  }
  return false;
}
