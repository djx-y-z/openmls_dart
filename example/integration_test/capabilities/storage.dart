import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/location.dart';
import '../support/party.dart';

/// An engine on the database at [path], closed when the capability ends.
Future<MlsEngine> _open(String path, Uint8List key) async {
  final engine = await MlsEngine.create(dbPath: path, encryptionKey: key);
  addTearDown(engine.close);
  return engine;
}

/// A group of [owner]'s, created in [engine] rather than in its own.
Future<Uint8List> _groupIn(MlsEngine engine, Party owner) async =>
    (await engine.createGroup(
      config: owner.config,
      signerBytes: owner.signer,
      credentialIdentity: owner.identity,
      signerPublicKey: owner.publicKey,
    )).groupId;

/// Where the platform has POSIX permissions on files: everywhere natively but
/// Windows.
final _hasPermissions =
    !kIsWeb && defaultTargetPlatform != TargetPlatform.windows;

void storageCapabilities() {
  group('storage', () {
    capability('a database keeps its groups across close and reopen, and '
        'they go on working', () async {
      final alice = await Party.create('alice');
      final bob = await Party.create('bob');
      final path = await freshDatabase('kept');
      final key = freshKey();

      var engine = await _open(path, key);
      final group = await _groupIn(engine, alice);
      final added = await engine.addMembers(
        groupIdBytes: group,
        signerBytes: alice.signer,
        keyPackagesBytes: [await bob.keyPackage()],
      );
      await engine.mergePendingCommit(groupIdBytes: group);
      await bob.join(added.welcome);
      final whileAway = await bob.send(group, 'while you were away');
      await engine.close();

      engine = await _open(path, key);
      // The groups are found again from storage alone, which is what an
      // application needs after a restart.
      expect(await engine.groupIds(), [group]);
      expect(await engine.groupEpoch(groupIdBytes: group), BigInt.one);
      expect(await engine.groupMembers(groupIdBytes: group), hasLength(2));
      final received = await engine.processMessage(
        groupIdBytes: group,
        messageBytes: whileAway,
      );
      expect(textOf(received.applicationMessage!), 'while you were away');
      final back = await engine.createMessage(
        groupIdBytes: group,
        signerBytes: alice.signer,
        message: bytesOf('back again'),
      );
      expect(
        textOf((await bob.receive(group, back.ciphertext)).applicationMessage!),
        'back again',
      );
    });

    capability('a database is read only with its own key', () async {
      final alice = await Party.create('alice');
      final path = await freshDatabase('keyed');
      final key = freshKey();
      final engine = await _open(path, key);
      final group = await _groupIn(engine, alice);
      await engine.close();

      // Refused as it opens, on every platform, by what each one reads first:
      // natively SQLCipher checks the key; on the web, where every entry is
      // encrypted on its own with AES-GCM, the schema version is one, and it
      // does not decrypt.
      await expectLater(
        MlsEngine.create(dbPath: path, encryptionKey: freshKey()),
        throwsA(
          predicate(
            (error) => '$error'.contains(
              kIsWeb ? 'decrypt failed' : 'Encryption key verification failed',
            ),
          ),
        ),
      );

      // With its own key, the group is there as it was.
      final again = await _open(path, key);
      expect(await again.groupEpoch(groupIdBytes: group), BigInt.zero);
    });

    capability(
      kIsWeb
          ? 'a second engine on the same database shares it, as a second '
                'tab would'
          : 'a second engine on the same database file is refused until the '
                'first one closes',
      () async {
        final alice = await Party.create('alice');
        final path = await freshDatabase('one-at-a-time');
        final key = freshKey();
        final first = await _open(path, key);
        final group = await _groupIn(first, alice);

        if (kIsWeb) {
          // Tabs come and go at the user's hand, so a second one is not
          // refused: every operation takes a Web Lock named after the
          // database instead, and the two take turns.
          final second = await _open(path, key);
          expect(await second.groupEpoch(groupIdBytes: group), BigInt.zero);
        } else {
          // One engine per file: a second one, in this app or in another
          // process, would overwrite the first one's state. It waits out a
          // five-second timeout before it gives up.
          await expectLater(
            MlsEngine.create(dbPath: path, encryptionKey: key),
            throwsA(predicate((error) => '$error'.contains('already open'))),
          );
          await first.close();
          final second = await _open(path, key);
          expect(await second.groupEpoch(groupIdBytes: group), BigInt.zero);
        }
      },
    );

    if (_hasPermissions) {
      capability('a database file, and its lock file, are for their owner '
          'alone', () async {
        final alice = await Party.create('alice');
        final path = await freshDatabase('private');
        final engine = await _open(path, freshKey());
        await _groupIn(engine, alice);

        expect(permissionsOf(path), 0x180, reason: 'rw------- (0600)');
        expect(permissionsOf('$path.lock'), 0x180, reason: 'rw------- (0600)');
      });
    }
  });
}
