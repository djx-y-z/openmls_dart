import 'package:flutter_test/flutter_test.dart';

import 'package:openmls_example/main.dart';

void main() {
  testWidgets('App builds successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenmlsExampleApp());

    // Verify app title is displayed
    expect(find.text('openmls Example'), findsOneWidget);

    // Verify Run Demo button exists
    expect(find.text('Run Demo'), findsOneWidget);
  });

  testWidgets('Run Demo button triggers demo', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenmlsExampleApp());

    // Tap the Run Demo button
    await tester.tap(find.text('Run Demo'));
    await tester.pump();

    // Verify demo output appears
    expect(find.textContaining('Running demo...'), findsOneWidget);
  });
}
