import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/export/export_destination_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.archivale/export_destination-test');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('mobile save copy sends exact create-document inputs', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return 'completed';
        });
    final gateway = SystemExportDestinationGateway(
      saveCopyChannel: channel,
      useNativeMobileSaveCopy: true,
    );

    final result = await gateway.saveCopy(
      File('/private/generated_exports/reports/report-1.pdf'),
      suggestedName: 'report-1.pdf',
      mimeType: 'application/pdf',
    );

    expect(result, ExportDestinationResult.completed);
    expect(received!.method, 'saveCopy');
    expect(received!.arguments, {
      'sourcePath': '/private/generated_exports/reports/report-1.pdf',
      'suggestedName': 'report-1.pdf',
      'mimeType': 'application/pdf',
    });
  });

  test(
    'mobile save copy preserves dismissed and unavailable outcomes',
    () async {
      var nativeOutcome = 'dismissed';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => nativeOutcome);
      final gateway = SystemExportDestinationGateway(
        saveCopyChannel: channel,
        useNativeMobileSaveCopy: true,
      );
      final file = File('/private/generated_exports/archives/archive-1.zip');

      expect(
        await gateway.saveCopy(
          file,
          suggestedName: 'archive-1.zip',
          mimeType: 'application/zip',
        ),
        ExportDestinationResult.dismissed,
      );
      nativeOutcome = 'unexpected';
      expect(
        await gateway.saveCopy(
          file,
          suggestedName: 'archive-1.zip',
          mimeType: 'application/zip',
        ),
        ExportDestinationResult.unavailable,
      );
    },
  );

  test(
    'mobile save copy fails closed when the plugin is unavailable',
    () async {
      final gateway = SystemExportDestinationGateway(
        saveCopyChannel: channel,
        useNativeMobileSaveCopy: true,
      );

      expect(
        await gateway.saveCopy(
          File('/private/generated_exports/reports/report-1.pdf'),
          suggestedName: 'report-1.pdf',
          mimeType: 'application/pdf',
        ),
        ExportDestinationResult.unavailable,
      );
    },
  );
}
