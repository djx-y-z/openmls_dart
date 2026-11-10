import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openmls_example/main.dart';

import '../support/harness.dart';

/// Waits until [finder] matches.
///
/// Not `pumpAndSettle`, and not `pump` either. A demo's spinner animates for as
/// long as its native call runs, so settling would never happen; and `pump`
/// waits for a frame, which never comes once the app is told it is hidden — a
/// desktop window covered by another one is enough — so the test would hang
/// without saying why. A forced frame is drawn regardless, and this loop ends
/// at its deadline whatever happens.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure('Timed out waiting for $finder.');
    }
    tester.binding.scheduleForcedFrame();
    await tester.binding.delayed(const Duration(milliseconds: 50));
  }
}

/// Runs one tab's demo and returns what it printed.
Future<String> _runDemo(WidgetTester tester, String tab, String id) async {
  // The tab bar scrolls, and on a phone not every tab fits. Hit-testable, not
  // just present, for each tap here: a tap on something off screen lands
  // nowhere.
  await tester.ensureVisible(find.text(tab));
  await _waitFor(tester, find.text(tab).hitTestable());
  await tester.tap(find.text(tab));

  // The same again for the button: its page ignores pointers until the
  // transition ends.
  final run = find.byKey(ValueKey('run-$id'));
  await _waitFor(tester, run);
  await tester.ensureVisible(run);
  await _waitFor(tester, run.hitTestable());
  await tester.tap(run);

  final result = find.byKey(ValueKey('result-$id'));
  await _waitFor(tester, result);
  return tester.widget<SelectableText>(result).data!;
}

void appCapabilities() {
  group('the example app', () {
    // Not `capability`: this one drives the widget tree, and it is the app's
    // own `initState` that calls `Openmls.init()` here — by now a call that
    // returns at once, the capabilities above having initialized the library
    // first. Last among them, because the app's `dispose` calls
    // `Openmls.cleanup()`.
    testWidgets(
      'initializes and runs every demo',
      (tester) => withinLimit(const Duration(minutes: 5), () async {
        // By default a live test only draws when it pumps. This one waits on
        // native calls instead, so the app has to draw on its own.
        final binding = IntegrationTestWidgetsFlutterBinding.instance;
        final framePolicy = binding.framePolicy;
        addTearDown(() => binding.framePolicy = framePolicy);
        binding.framePolicy =
            LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

        await tester.pumpWidget(const MyApp());

        // `init()` failing puts its error on the screen instead of the tabs.
        // On the web that is also what a missing `web/pkg/` looks like. Either
        // way the wait ends, and the error is the failure's reason.
        final failed = find.text('openmls failed to initialize');
        await _waitFor(
          tester,
          find.byWidgetPredicate(
            (widget) =>
                widget is TabBarView ||
                (widget is Text &&
                    widget.data == 'openmls failed to initialize'),
          ),
        );
        expect(
          failed,
          findsNothing,
          reason: [
            for (final text in tester.widgetList<SelectableText>(
              find.byType(SelectableText),
            ))
              text.data,
          ].join('\n'),
        );

        // What each demo prints when every step of it worked. A step that
        // throws replaces the whole result with its error.
        const demos = {
          ('Keys', 'keys'): [
            'Match: true',
            'Type: 1 (1 = Basic)',
            'Type: 2 (2 = X.509)',
          ],
          ('Groups', 'groups'): [
            'Match: true',
            'Decrypted: "Hello, Bob!"',
            'Reply: "Hi Alice!"',
            '8. processMessageWithInspect',
          ],
          ('State', 'state'): [
            '10. groupId() match: true',
            '14. PSK (epoch 0):',
          ],
          ('Proposals', 'proposals'): ['7. Alice left, final members:'],
          ('Adv Groups', 'advanced-groups'): [
            'ID match: true',
            '10. leaveGroupViaSelfRemove',
          ],
          ('Adv Proposals', 'advanced-proposals'): ['11. mergePendingCommit'],
          ('Post-Quantum', 'post-quantum'): ['RESULT: PASS'],
        };
        for (final MapEntry(key: (tab, id), value: expected) in demos.entries) {
          final printed = await _runDemo(tester, tab, id);
          expect(printed, isNot(contains('Error:')), reason: tab);
          for (final line in expected) {
            expect(printed, contains(line), reason: tab);
          }
        }
      }),
      // A backstop only: the limit above fires first, as in `capability`.
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });
}
