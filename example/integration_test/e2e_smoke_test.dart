import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lib_mlx_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads a model, serves OpenAI chat, and unloads', (tester) async {
    expect(Platform.isIOS, isTrue);

    await tester.pumpWidget(const LibMlxExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('lib_mlx runtime'), findsOneWidget);
    expect(find.text('idle'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).first,
      '/tmp/gemma-4-e2b-it-4bit',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await waitForText(tester, 'model ready');

    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await waitForText(tester, 'server running');
    expect(find.textContaining('http://127.0.0.1:'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Chat'));
    await waitForText(tester, 'chat complete');
    expect(find.textContaining('Paris'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await waitForText(tester, 'server stopped');

    await tester.tap(find.widgetWithText(FilledButton, 'Unload'));
    await waitForText(tester, 'unloaded');
  });
}

Future<void> waitForText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  for (var attempt = 0; attempt < 100; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  expect(finder, findsOneWidget);
}
