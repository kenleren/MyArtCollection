import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/app.dart';
import 'package:my_art_collection/app/app_routes.dart';

void main() {
  testWidgets('intro screen shows brand once and value heading once', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MyArtCollectionApp(initialRoute: AppRoutes.splash),
    );
    await tester.pumpAndSettle();

    expect(find.text('MyArtCollection'), findsOneWidget);
    expect(find.text('Private artwork records'), findsOneWidget);
    expect(find.text('AI drafts. You confirm.'), findsOneWidget);
  });

  testWidgets('collection shell renders and can open add artwork', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MyArtCollectionApp(initialRoute: AppRoutes.collection),
    );
    await tester.pumpAndSettle();

    expect(find.text('Collection'), findsWidgets);
    expect(find.text('Incomplete'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('No artworks yet'), findsOneWidget);
    expect(find.text('Blue Interior Study'), findsNothing);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));

    expect(find.text('Add artwork'), findsWidgets);
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Import photo'), findsOneWidget);
  });

  testWidgets('first artwork prototype reaches report and export preview', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MyArtCollectionApp(initialRoute: AppRoutes.collection),
    );
    await tester.pumpAndSettle();

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));
    await tapVisible(tester, find.text('Import photo'));
    expect(find.text('Photo imported'), findsOneWidget);
    expect(find.text('Upload-failure state'), findsOneWidget);

    await tapVisible(tester, find.text('Review AI draft'));
    expect(find.text('AI draft review'), findsWidgets);
    expect(find.text('AI-suggested'), findsWidgets);
    expect(find.text('User confirmed'), findsOneWidget);
    expect(find.text('Document-extracted'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);

    await tapVisible(tester, find.text('Confirm suggested fields'));
    expect(find.text('Verified by you'), findsWidgets);
    expect(find.text('Blue Interior Study'), findsWidgets);
    expect(find.text('Record state: Verified by you'), findsOneWidget);

    await tapVisible(tester, find.text('Attach receipt placeholder'));
    expect(find.text('Documents'), findsWidgets);
    expect(find.text('gallery-receipt-2025.pdf'), findsOneWidget);
    expect(find.text('Attach document placeholder'), findsOneWidget);

    await tapVisible(tester, find.text('Report preview'));
    expect(find.text('Generate an insurance-ready PDF'), findsWidgets);
    expect(
      find.text('User-provided insurance value: USD 2,400.'),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Export archive preview'));
    expect(find.text('Export record package'), findsWidgets);
    expect(find.text('ZIP archive preview'), findsOneWidget);
    expect(find.text('User-provided insurance values only.'), findsOneWidget);
  });

  testWidgets('settings shell routes render the settings tab', (
    WidgetTester tester,
  ) async {
    for (final route in [AppRoutes.collectionSettings, AppRoutes.settings]) {
      await tester.pumpWidget(MyArtCollectionApp(initialRoute: route));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Privacy and storage'), findsWidgets);
      expect(find.text('Disconnect backup'), findsOneWidget);
      expect(find.text('No artworks yet'), findsNothing);
    }
  });
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
