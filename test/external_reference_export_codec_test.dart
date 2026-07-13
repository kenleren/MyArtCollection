import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/export/external_reference_export_codec.dart';
import 'package:my_art_collection/app/storage/external_reference.dart';

void main() {
  const codec = ExternalReferenceExportCodec();

  test(
    'encoder matches frozen compact UTF-8 bytes and decoder round trips',
    () {
      final fixture = Uint8List.fromList(
        base64Decode(
          File(
            'test/fixtures/external-reference-export-contract-v1.b64',
          ).readAsStringSync().trim(),
        ),
      );
      final encoded = codec.encode(_records.reversed.toList());

      expect(encoded, fixture);
      expect(codec.decodeStandalone(fixture).map((row) => row.id), [
        'reference-b',
        'reference-a',
      ]);
      expect(utf8.decode(encoded), isNot(endsWith('\n')));
      expect(encoded.take(3), isNot([0xef, 0xbb, 0xbf]));
    },
  );

  test('root distinguishes absent and always encodes an empty envelope', () {
    expect(
      codec.decodeRoot(const {}).status,
      ExternalReferenceExportDecodeStatus.absent,
    );
    final empty = codec.encode(const []);
    expect(
      utf8.decode(empty),
      '{"contract":"EXTERNAL_REFERENCE_EXPORT_CONTRACT_V1","version":1,"references":[]}',
    );
    expect(
      codec.decodeRoot({
        'external_references': jsonDecode(utf8.decode(empty)),
      }).status,
      ExternalReferenceExportDecodeStatus.present,
    );
    expect(
      () => codec.decodeRoot(const {'external_references': null}),
      throwsA(isA<ExternalReferenceExportException>()),
    );
  });

  test('strict decoder rejects envelope and field contract violations', () {
    _expectReject(codec, (envelope) => envelope['contract'] = 'UNKNOWN');
    _expectReject(codec, (envelope) => envelope['version'] = 2);
    _expectReject(codec, (envelope) => envelope['version'] = '1');
    _expectReject(codec, (envelope) => envelope.remove('contract'));
    _expectReject(codec, (envelope) => envelope['extension'] = true);
    _expectReject(codec, (envelope) => envelope['references'] = null);
    expect(
      () => codec.decodeSectionValue(const []),
      throwsA(isA<ExternalReferenceExportException>()),
    );

    _expectReject(codec, (envelope) => _first(envelope).remove('label'));
    _expectReject(codec, (envelope) => _first(envelope)['label'] = 12);
    _expectReject(codec, (envelope) => _first(envelope)['sort_order'] = '0');
    _expectReject(
      codec,
      (envelope) => _first(envelope)['reference_type'] = 'artist',
    );
    _expectReject(codec, (envelope) => _first(envelope)['origin'] = 'provider');
    _expectReject(
      codec,
      (envelope) => _first(envelope)['review_state'] = 'draft',
    );
    _expectReject(
      codec,
      (envelope) => _first(envelope)['created_at'] = '2026-02-30T00:00:00.000Z',
    );
    _expectReject(
      codec,
      (envelope) => _first(envelope)['url'] = 'http://example.com',
    );
  });

  test('privacy allowlist rejects every forbidden metadata family', () {
    const forbidden = [
      'raw_url',
      'prior_url',
      'research_id',
      'citation_id',
      'snippet',
      'fetched_title',
      'fetched_content',
      'preview',
      'cache',
      'local_path',
      'device_path',
      'account_id',
      'provider_id',
      'attachment_metadata',
      'analytics',
      'telemetry',
      'launch_history',
      'extensions',
    ];
    for (final field in forbidden) {
      _expectReject(codec, (envelope) => _first(envelope)[field] = 'forbidden');
    }
  });

  test(
    'decoder rejects duplicate identity, URL, gaps and noncanonical order',
    () {
      _expectReject(codec, (envelope) {
        final rows = _rows(envelope);
        rows[1]['reference_id'] = rows[0]['reference_id'];
      });
      _expectReject(codec, (envelope) {
        final rows = _rows(envelope);
        rows[1]['artwork_id'] = rows[0]['artwork_id'];
        rows[1]['url'] = rows[0]['url'];
        rows[1]['sort_order'] = 1;
      });
      _expectReject(codec, (envelope) {
        final rows = _rows(envelope);
        rows[1]['artwork_id'] = rows[0]['artwork_id'];
        rows[1]['sort_order'] = 2;
      });
      _expectReject(codec, (envelope) {
        final reversed = _rows(envelope).reversed.toList();
        _rows(envelope).setAll(0, reversed);
      });
    },
  );

  test('standalone decoder rejects whitespace, BOM and trailing bytes', () {
    final canonical = codec.encode(_records);
    for (final bytes in [
      Uint8List.fromList([...canonical, 0x0a]),
      Uint8List.fromList([0x20, ...canonical]),
      Uint8List.fromList([0xef, 0xbb, 0xbf, ...canonical]),
    ]) {
      expect(
        () => codec.decodeStandalone(bytes),
        throwsA(isA<ExternalReferenceExportException>()),
      );
    }
  });

  test('encoder preflight rejects invalid rows before producing bytes', () {
    final invalid = _records.first.copyWith(url: 'http://example.com');
    expect(
      () => codec.encode([invalid]),
      throwsA(isA<ExternalReferenceExportException>()),
    );
  });
}

void _expectReject(
  ExternalReferenceExportCodec codec,
  void Function(Map<String, Object?> envelope) mutate,
) {
  final envelope =
      jsonDecode(utf8.decode(codec.encode(_records))) as Map<String, Object?>;
  mutate(envelope);
  expect(
    () => codec.decodeSectionValue(envelope),
    throwsA(isA<ExternalReferenceExportException>()),
  );
}

List<Map<String, Object?>> _rows(Map<String, Object?> envelope) =>
    (envelope['references'] as List<Object?>).cast<Map<String, Object?>>();

Map<String, Object?> _first(Map<String, Object?> envelope) =>
    _rows(envelope).first;

final _records = [
  ExternalReferenceRecord(
    id: 'reference-b',
    artworkId: 'artwork-a',
    type: ExternalReferenceType.galleryOrArtist,
    label: 'Gallery A',
    url: 'https://gallery.example/object?b=2&a=1#record',
    origin: ExternalReferenceOrigin.manual,
    reviewState: ExternalReferenceReviewState.confirmed,
    lastConfirmedAt: DateTime.utc(2026, 7, 13, 8),
    createdAt: DateTime.utc(2026, 7, 13, 8),
    updatedAt: DateTime.utc(2026, 7, 13, 8),
    sortOrder: 0,
  ),
  ExternalReferenceRecord(
    id: 'reference-a',
    artworkId: 'artwork-b',
    type: ExternalReferenceType.museumOrInstitution,
    label: null,
    url: 'https://museum.example/',
    origin: ExternalReferenceOrigin.aiSuggestion,
    reviewState: ExternalReferenceReviewState.suggested,
    lastConfirmedAt: null,
    createdAt: DateTime.utc(2026, 7, 13, 8, 1),
    updatedAt: DateTime.utc(2026, 7, 13, 8, 1),
    sortOrder: 0,
  ),
];
