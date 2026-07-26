import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

import '../test_helpers.dart';

/// The bytes every unencrypted SQLite file starts with.
final _sqliteHeader = Uint8List.fromList([
  ...utf8.encode('SQLite format 3'),
  0,
]);

/// Whether [haystack] contains [needle] anywhere.
bool _contains(List<int> haystack, List<int> needle) {
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var matched = true;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[start + i] != needle[i]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

void main() {
  late String dbPath;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('openmls_db_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    dbPath = '${dir.path}/mls.db';
  });

  /// Create a group so the database holds real MLS state, then close.
  Future<void> writeGroupState(MlsEngine engine, String identity) async {
    final id = TestIdentity.create(identity);
    await engine.createGroup(
      config: defaultConfig(),
      signerBytes: id.signerBytes,
      credentialIdentity: id.credentialIdentity,
      signerPublicKey: id.publicKey,
    );
    await engine.createKeyPackage(
      ciphersuite: ciphersuite,
      signerBytes: id.signerBytes,
      credentialIdentity: id.credentialIdentity,
      signerPublicKey: id.publicKey,
    );
  }

  group('encryption at rest', () {
    test('the database file is encrypted', () async {
      const identity = 'plaintext-canary-identity';
      final engine = await MlsEngine.create(
        dbPath: dbPath,
        encryptionKey: testEncryptionKey(),
      );
      await writeGroupState(engine, identity);
      await engine.close();

      final bytes = File(dbPath).readAsBytesSync();
      expect(bytes, isNotEmpty);
      // SQLCipher encrypts the header too, so not even the file magic survives.
      expect(_contains(bytes.take(16).toList(), _sqliteHeader), isFalse);
      // Nothing recognizable from the stored group state either.
      expect(_contains(bytes, utf8.encode(identity)), isFalse);
      expect(_contains(bytes, utf8.encode('KeyPackage')), isFalse);
    });

    test('a wrong key fails closed and leaves the data intact', () async {
      final rightKey = testEncryptionKey();
      final wrongKey = testEncryptionKey();

      final engine = await MlsEngine.create(
        dbPath: dbPath,
        encryptionKey: rightKey,
      );
      await writeGroupState(engine, 'wrong-key-test');
      await engine.close();

      await expectLater(
        MlsEngine.create(dbPath: dbPath, encryptionKey: wrongKey),
        throwsA(
          predicate<Object>(
            (e) => e.toString().contains('Encryption key verification failed'),
          ),
        ),
      );

      // The rejected attempt did not damage anything.
      final reopened = await MlsEngine.create(
        dbPath: dbPath,
        encryptionKey: rightKey,
      );
      expect(reopened.isClosed(), isFalse);
      await reopened.close();
    });

    test('a short key is rejected', () async {
      await expectLater(
        MlsEngine.create(
          dbPath: dbPath,
          encryptionKey: Uint8List.fromList(List.filled(16, 7)),
        ),
        throwsA(
          predicate<Object>(
            (e) => e.toString().contains('encryption_key must be 32 bytes'),
          ),
        ),
      );
    });
  });

  group('single writer', () {
    // Two connections to one file would each load a snapshot, operate on it
    // and write the diff back, silently overwriting each other's group state.
    // The database is locked exclusively so the second one is refused instead.

    test('a second engine on the same file is refused', () async {
      final key = testEncryptionKey();
      final first = await MlsEngine.create(dbPath: dbPath, encryptionKey: key);
      await writeGroupState(first, 'single-writer');

      await expectLater(
        MlsEngine.create(dbPath: dbPath, encryptionKey: key),
        throwsA(
          predicate<Object>((e) => e.toString().contains('already open')),
        ),
      );

      // Closing the first engine hands the file over.
      await first.close();
      final second = await MlsEngine.create(dbPath: dbPath, encryptionKey: key);
      expect(second.isClosed(), isFalse);
      await second.close();
    });

    test('separate database files stay independent', () async {
      final other = '$dbPath.other';
      final first = await MlsEngine.create(
        dbPath: dbPath,
        encryptionKey: testEncryptionKey(),
      );
      final second = await MlsEngine.create(
        dbPath: other,
        encryptionKey: testEncryptionKey(),
      );

      await writeGroupState(first, 'db-one');
      await writeGroupState(second, 'db-two');

      await first.close();
      await second.close();
      addTearDown(() => File(other).deleteSync());
    });
  });
}
