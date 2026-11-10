import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';
import '../support/party.dart';

void ciphersuiteCapabilities() {
  group('ciphersuites', () {
    capability('every suite the package names is one it supports', () async {
      expect(supportedCiphersuites(), unorderedEquals(MlsCiphersuite.values));
    });

    // One capability per suite, so that a failure names the suite, and each
    // has a time limit of its own. The bridge carries an enum by its index, so
    // a value out of step with the native list would give a working group on a
    // suite nobody asked for: the suite is read back from the group.
    for (final suite in MlsCiphersuite.values) {
      capability('${suite.name}: a group is created, joined, rekeyed, and '
          'talks both ways', () async {
        final alice = await Party.create('alice', suite: suite);
        final bob = await Party.create('bob', suite: suite);
        final group = await groupOf(alice, [bob]);
        for (final party in [alice, bob]) {
          expect(
            await party.engine.groupCiphersuite(groupIdBytes: group),
            suite,
          );
        }

        final ping = await alice.send(group, 'ping on ${suite.name}');
        expect(
          textOf((await bob.receive(group, ping)).applicationMessage!),
          'ping on ${suite.name}',
        );

        // A commit on this suite, too: Bob's new keys reach Alice.
        final update = await bob.engine.selfUpdate(
          groupIdBytes: group,
          signerBytes: bob.signer,
        );
        await alice.receive(group, update.commit);
        expect(await alice.epochOf(group), await bob.epochOf(group));
        expect(await alice.epochOf(group), BigInt.two);

        final pong = await bob.send(group, 'pong on ${suite.name}');
        expect(
          textOf((await alice.receive(group, pong)).applicationMessage!),
          'pong on ${suite.name}',
        );
      });
    }
  });
}
