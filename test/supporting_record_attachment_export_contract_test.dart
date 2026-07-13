import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'v1 attachment fixture enforces exact metadata and canonical paths',
    () async {
      final file = File(
        'test/fixtures/supporting-record-attachment-export-contract-v1.json',
      );
      final fixture =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final attachments = fixture['attachments'] as List<dynamic>;
      const includedKeys = <String>{
        'attachment_id',
        'artwork_id',
        'attachment_type',
        'attachment_role',
        'file_name',
        'mime_type',
        'file_size_bytes',
        'checksum_sha256',
        'imported_at',
        'lifecycle_status',
        'archive_status',
        'payload_path',
      };
      const excludedKeys = <String>{
        'attachment_id',
        'artwork_id',
        'attachment_type',
        'attachment_role',
        'lifecycle_status',
        'archive_status',
      };
      final payloadPaths = <String>{};

      expect(
        fixture['contract_version'],
        'supporting_record_attachment_export_contract_v1',
      );
      for (final rawAttachment in attachments) {
        final attachment = rawAttachment as Map<String, dynamic>;
        final status = attachment['archive_status'] as String;
        if (status == 'included') {
          expect(attachment.keys.toSet(), includedKeys);
          final payloadPath = attachment['payload_path'] as String;
          expect(
            _isCanonicalPayloadPath(
              payloadPath,
              attachment['attachment_id'] as String,
            ),
            isTrue,
          );
          expect(payloadPaths.add(payloadPath), isTrue);
          continue;
        }
        expect(attachment.keys.toSet(), excludedKeys);
      }

      final maliciousPaths =
          fixture['malicious_payload_paths'] as List<dynamic>;
      for (final path in maliciousPaths.cast<String>()) {
        expect(_isCanonicalPayloadPath(path, 'attachment-active'), isFalse);
      }
      final forbiddenEntries =
          fixture['forbidden_field_entries'] as List<dynamic>;
      for (final rawEntry in forbiddenEntries) {
        final entry = rawEntry as Map<String, dynamic>;
        final status = entry['archive_status'] as String;
        expect(
          entry.keys.toSet(),
          isNot(status == 'included' ? includedKeys : excludedKeys),
        );
      }
    },
  );
}

bool _isCanonicalPayloadPath(String path, String attachmentId) {
  if (path.contains('\\') ||
      path.contains('%') ||
      path.contains('?') ||
      path.contains('#') ||
      path.startsWith('/') ||
      path.contains('//')) {
    return false;
  }
  final segments = path.split('/');
  if (segments.length != 3 ||
      segments[0] != 'attachments' ||
      segments[1] != attachmentId ||
      segments.any(
        (segment) => segment.isEmpty || segment == '.' || segment == '..',
      )) {
    return false;
  }
  return RegExp(
    r'^payload\.(pdf|jpg|jpeg|png|heic|heif)$',
  ).hasMatch(segments[2]);
}
