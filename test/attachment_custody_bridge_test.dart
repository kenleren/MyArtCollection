import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/storage/attachment_custody_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.archivale/attachment_custody_v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('publishes only opaque ids and canonical payload names', () async {
    MethodCall? call;
    messenger.setMockMethodCallHandler(channel, (received) async {
      call = received;
      return <String, Object?>{'outcome': 'published'};
    });

    final result = await AttachmentCustodyBridge(channel: channel).publish(
      operationId: 'publish-001',
      artworkId: 'artwork-001',
      attachmentId: 'attachment-001',
      canonicalName: 'payload.pdf',
      sourceFile: File('/private/import.pdf'),
    );

    expect(result.outcome, AttachmentCustodyOutcome.published);
    expect(call!.method, 'publish');
    expect(call!.arguments, <String, Object?>{
      'operationId': 'publish-001',
      'artworkId': 'artwork-001',
      'attachmentId': 'attachment-001',
      'canonicalName': 'payload.pdf',
      'sourcePath': '/private/import.pdf',
    });
  });

  test('routes deterministic publication recovery operations', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      expect(call.arguments, <String, Object?>{
        'operationId': 'publish-001',
        'artworkId': 'artwork-001',
        'attachmentId': 'attachment-001',
        'canonicalName': 'payload.pdf',
      });
      return <String, Object?>{'outcome': 'publicationAbsent'};
    });
    final bridge = AttachmentCustodyBridge(channel: channel);

    await bridge.publicationStatus(
      operationId: 'publish-001',
      artworkId: 'artwork-001',
      attachmentId: 'attachment-001',
      canonicalName: 'payload.pdf',
    );
    await bridge.recoverPublication(
      operationId: 'publish-001',
      artworkId: 'artwork-001',
      attachmentId: 'attachment-001',
      canonicalName: 'payload.pdf',
    );
    await bridge.rollbackPublication(
      operationId: 'publish-001',
      artworkId: 'artwork-001',
      attachmentId: 'attachment-001',
      canonicalName: 'payload.pdf',
    );
    await bridge.cleanupPublication(
      operationId: 'publish-001',
      artworkId: 'artwork-001',
      attachmentId: 'attachment-001',
      canonicalName: 'payload.pdf',
    );

    expect(methods, <String>[
      'publicationStatus',
      'recoverPublication',
      'rollbackPublication',
      'cleanupPublication',
    ]);
  });

  test('parses publication and erasure-control state', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return <String, Object?>{
        'outcome': 'erasureOwned',
        'owner': 'erase-001',
        'phase': 'erasing',
        'publications': <Object?>[
          <String, Object?>{
            'operationId': 'publish-001',
            'artworkId': 'artwork-001',
            'attachmentId': 'attachment-001',
            'canonicalName': 'payload.pdf',
            'phase': 'staged',
            'size': 42,
            'sha256': 'a' * 64,
          },
        ],
      };
    });

    final result = await AttachmentCustodyBridge(
      channel: channel,
    ).readErasureControl('erase-001');

    expect(result.outcome, AttachmentCustodyOutcome.erasureOwned);
    expect(result.owner, 'erase-001');
    expect(result.phase, 'erasing');
    expect(result.publications.single.operationId, 'publish-001');
    expect(result.publications.single.size, 42);
    expect(result.isSuccess, isTrue);
  });

  test('rejects paths, dot segments, and unapproved payload names', () {
    final bridge = AttachmentCustodyBridge(channel: channel);

    expect(
      () => bridge.publicationStatus(
        operationId: '../operation',
        artworkId: 'artwork-001',
        attachmentId: 'attachment-001',
        canonicalName: 'payload.pdf',
      ),
      throwsArgumentError,
    );
    expect(
      () => bridge.remove(
        artworkId: '../artwork',
        attachmentId: 'attachment-001',
        canonicalName: 'payload.pdf',
      ),
      throwsArgumentError,
    );
    expect(
      () => bridge.remove(
        artworkId: 'artwork-001',
        attachmentId: 'attachment/001',
        canonicalName: 'payload.pdf',
      ),
      throwsArgumentError,
    );
    expect(
      () => bridge.remove(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-001',
        canonicalName: 'payload.exe',
      ),
      throwsArgumentError,
    );
  });

  test('maps unknown native outcomes to a fail-closed failure', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return <String, Object?>{'outcome': 'newNativeOutcome'};
    });

    final result = await AttachmentCustodyBridge(
      channel: channel,
    ).capabilities();

    expect(result.outcome, AttachmentCustodyOutcome.ioFailure);
    expect(result.isSuccess, isFalse);
  });
}
