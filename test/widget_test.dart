import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subay/main.dart';

void main() {
  testWidgets('SUBAY app renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const SubayApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}