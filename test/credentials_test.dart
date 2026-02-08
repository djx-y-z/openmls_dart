import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    await Openmls.init();
  });

  group('X.509 credentials', () {
    test('create and inspect X.509 credential', () {
      final cert1 = Uint8List.fromList([0x30, 0x82, 0x01, 0x22]); // mock DER
      final cert2 = Uint8List.fromList([0x30, 0x82, 0x01, 0x33]);
      final cred = MlsCredential.x509(certificateChain: [cert1, cert2]);

      expect(cred.credentialType(), equals(2)); // X509 = 2

      final certs = cred.certificates();
      expect(certs, hasLength(2));
      expect(certs[0], equals(cert1));
      expect(certs[1], equals(cert2));
    });

    test('serialized content round-trip', () {
      final cert = Uint8List.fromList([1, 2, 3, 4, 5]);
      final cred = MlsCredential.x509(certificateChain: [cert]);

      final content = cred.serializedContent();
      expect(content, isNotEmpty);
    });

    test('serialize/deserialize X.509 credential', () {
      final cert = Uint8List.fromList(utf8.encode('test-certificate'));
      final cred = MlsCredential.x509(certificateChain: [cert]);

      final serialized = cred.serialize();
      final deserialized = MlsCredential.deserialize(bytes: serialized);

      expect(deserialized.credentialType(), equals(2));
      final certs = deserialized.certificates();
      expect(certs, hasLength(1));
      expect(certs[0], equals(cert));
    });

    test('identity() fails on X.509 credential', () {
      final cert = Uint8List.fromList([1, 2, 3]);
      final cred = MlsCredential.x509(certificateChain: [cert]);

      expect(cred.identity, throwsA(isA<Object>()));
    });

    test('certificates() fails on Basic credential', () {
      final cred = MlsCredential.basic(identity: utf8.encode('alice'));

      expect(cred.certificates, throwsA(isA<Object>()));
    });
  });
}
