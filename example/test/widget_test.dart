import 'package:flutter_test/flutter_test.dart';

import 'package:openmls_example/main.dart';

void main() {
  testWidgets('App builds successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // Verify app title is displayed
    expect(find.text('openmls Example'), findsOneWidget);
  });
}
