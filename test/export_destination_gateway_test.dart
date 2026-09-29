import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/export/export_artifact_store.dart';
import 'package:my_art_collection/app/export/export_destination_gateway.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.archivale/export_destination-test');
  late Directory temp;
  late ExportArtifactStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('export_destination_test_');
    store = await ExportArtifactStore.openAt(
      Directory(p.join(temp.path, 'generated_exports')),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  test('mobile save copy sends only committed artifact inputs', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return 'completed';
        });
    final artifact = await _commitReport(store);
    final gateway = SystemExportDestinationGateway(
      saveCopyChannel: channel,
      useNativeMobileSaveCopy: true,
    );

    final result = await gateway.saveCopy(artifact);

    expect(result, ExportDestinationResult.completed);
    expect(received!.method, 'saveCopy');
    expect(received!.arguments, {
      'sourcePath': artifact.file.path,
      'suggestedName': artifact.displayName,
      'mimeType': 'application/pdf',
      'expectedByteSize': artifact.byteSize,
      'expectedSha256': artifact.checksumSha256,
    });
  });

  test(
    'reopened store cannot recover publication authority from sidecars',
    () async {
      final report = await _commitReport(store);
      final archive = await _commitArchive(store);
      expect(
        await store.latest(ExportArtifactKind.report, subjectId: 'artwork-1'),
        isNotNull,
      );
      expect(await store.latest(ExportArtifactKind.archive), isNotNull);
      final reopened = await ExportArtifactStore.openAt(store.root);
      expect(
        await reopened.latest(
          ExportArtifactKind.report,
          subjectId: 'artwork-1',
        ),
        isNull,
      );
      expect(await reopened.latest(ExportArtifactKind.archive), isNull);
      expect(await reopened.validate(report), isNull);
      expect(await reopened.validate(archive), isNull);
      expect(await report.file.exists(), isTrue);
      expect(await archive.file.exists(), isTrue);
    },
  );

  test(
    'consistent payload and sidecar substitution cannot refresh authority',
    () async {
      var nativeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            nativeCalls++;
            return 'completed';
          });
      final artifact = await _commitArchive(store);
      final revalidated = (await artifact.revalidate())!;
      final metadataFile = File('${artifact.file.path}.json');
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final replacement = [7, 8, 9];
      await artifact.file.writeAsBytes(replacement, flush: true);
      metadata['checksum_sha256'] = sha256.convert(replacement).toString();
      await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
      expect(await artifact.revalidate(), isNull);
      expect(await revalidated.revalidate(), isNull);
      expect(await store.latest(ExportArtifactKind.archive), isNull);
      final gateway = SystemExportDestinationGateway(
        saveCopyChannel: channel,
        useNativeMobileSaveCopy: true,
      );
      expect(
        await gateway.saveCopy(revalidated),
        ExportDestinationResult.unavailable,
      );
      expect(nativeCalls, 0);
    },
  );

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
      final artifact = await _commitArchive(store);

      expect(
        await gateway.saveCopy(artifact),
        ExportDestinationResult.dismissed,
      );
      nativeOutcome = 'unexpected';
      expect(
        await gateway.saveCopy(artifact),
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
        await gateway.saveCopy(await _commitReport(store)),
        ExportDestinationResult.unavailable,
      );
    },
  );

  test(
    'all destinations reject a post-commit bit flip before dispatch',
    () async {
      var nativeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            nativeCalls++;
            return 'completed';
          });
      final artifact = await _commitArchive(store);
      await artifact.file.writeAsBytes([9, 9, 9], flush: true);
      final gateway = SystemExportDestinationGateway(
        saveCopyChannel: channel,
        useNativeMobileSaveCopy: true,
      );

      expect(
        await gateway.saveCopy(artifact),
        ExportDestinationResult.unavailable,
      );
      expect(nativeCalls, 0);
      expect(await artifact.revalidate(), isNull);
    },
  );
}

Future<ExportArtifact> _commitReport(ExportArtifactStore store) async {
  final createdAt = DateTime.utc(2026, 7, 14, 9);
  final id = ExportArtifactStore.reportId('artwork-1', createdAt);
  final staging = await store.stagingFile(ExportArtifactKind.report, id);
  await staging.writeAsBytes([1, 2, 3], flush: true);
  return store.commit(
    kind: ExportArtifactKind.report,
    id: id,
    staging: staging,
    createdAt: createdAt,
    warnings: const [],
    subjectId: 'artwork-1',
  );
}

Future<ExportArtifact> _commitArchive(ExportArtifactStore store) async {
  final createdAt = DateTime.utc(2026, 7, 14, 9);
  final id = 'archive-${createdAt.microsecondsSinceEpoch}';
  final staging = await store.stagingFile(ExportArtifactKind.archive, id);
  await staging.writeAsBytes([4, 5, 6], flush: true);
  return store.commit(
    kind: ExportArtifactKind.archive,
    id: id,
    staging: staging,
    createdAt: createdAt,
    warnings: const [],
  );
}
