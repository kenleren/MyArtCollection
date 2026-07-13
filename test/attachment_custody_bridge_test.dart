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
      artworkId: 'artwork-001',
      attachmentId: 'attachment-001',
      canonicalName: 'payload.pdf',
      sourceFile: File('/private/import.pdf'),
    );

    expect(result.outcome, AttachmentCustodyOutcome.published);
    expect(call!.method, 'publish');
    expect(call!.arguments, <String, Object?>{
      'artworkId': 'artwork-001',
      'attachmentId': 'attachment-001',
      'canonicalName': 'payload.pdf',
      'sourcePath': '/private/import.pdf',
    });
  });

  test('rejects paths, dot segments, and unapproved payload names', () {
    final bridge = AttachmentCustodyBridge(channel: channel);

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
