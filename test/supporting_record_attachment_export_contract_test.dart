import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'v1 attachment fixture contains only approved exclusion metadata',
    () async {
      final file = File(
        'test/fixtures/supporting-record-attachment-export-contract-v1.json',
      );
      final fixture =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final attachments = fixture['attachments'] as List<dynamic>;

      expect(
        fixture['contract_version'],
        'supporting_record_attachment_export_contract_v1',
      );
      for (final rawAttachment in attachments) {
        final attachment = rawAttachment as Map<String, dynamic>;
        final status = attachment['archive_status'] as String;
        if (status == 'included') {
          expect(attachment['payload_path'], startsWith('attachments/'));
          expect(attachment['payload_path'], isNot(contains('/Users/')));
          continue;
        }
        expect(
          attachment.keys,
          unorderedEquals([
            'attachment_id',
            'artwork_id',
            'attachment_type',
            'attachment_role',
            'lifecycle_status',
            'archive_status',
          ]),
        );
      }
    },
  );
}
