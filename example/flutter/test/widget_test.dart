import 'package:flutter_test/flutter_test.dart';

import 'package:example_flutter/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());

    expect(find.text('Redis FFI Example'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
