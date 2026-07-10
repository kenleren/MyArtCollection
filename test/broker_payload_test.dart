import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/research/broker_payload.dart';

void main() {
  test('matches every authoritative #187 canonical payload vector', () async {
    final fixture =
        jsonDecode(
              await File(
                'backend/broker/fixtures/canonical-payload-v1.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final vectors = fixture['vectors']! as List<Object?>;

    for (final vectorValue in vectors) {
      final vector = vectorValue! as Map<String, Object?>;
      final request = vector['request']! as Map<String, Object?>;
      final image = request['image']! as Map<String, Object?>;
      final hints = request['draft_hints'] as Map<String, Object?>?;
      final payload = BrokerRequestPayload(
        requestId: request['request_id']! as String,
        consent: BrokerResearchConsent.approved(
          scope: _scope(request['consent_scope']! as String),
          copyVersion: request['consent_copy_version']! as String,
        ),
        derivative: BrokerImageDerivative(
          bytes: Uint8List.fromList(
            base64Decode(image['content_base64']! as String),
          ),
          longEdgePx: image['long_edge_px']! as int,
          mimeType: image['mime_type']! as String,
        ),
        draftHints: hints == null
            ? null
            : BrokerDraftHints(
                titleHint: hints['title_hint'] as String?,
                artistHint: hints['artist_hint'] as String?,
                searchTerms:
                    (hints['search_terms'] as List<Object?>?)?.cast<String>() ??
                    const [],
              ),
      );

      final actual = payload.toRequest();
      expect(actual, request, reason: vector['name'] as String);
      expect(
        canonicalPayloadJson(canonicalBrokerPayloadDocument(actual)),
        vector['canonical_json'],
        reason: vector['name'] as String,
      );
      expect(actual['payload_hash'], vector['sha256']);
      expect(actual, isNot(contains('canonical_payload_version')));
    }
  });

  test(
    'allows only approved fields and rejects hints under image-only consent',
    () {
      final payload = BrokerRequestPayload(
        requestId: '11111111-1111-4111-8111-111111111111',
        consent: const BrokerResearchConsent.approved(
          scope: BrokerConsentScope.imageOnly,
          copyVersion: 'research-consent-v1',
        ),
        derivative: BrokerImageDerivative(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          longEdgePx: 1600,
        ),
        draftHints: const BrokerDraftHints(titleHint: 'Must not be sent'),
      );

      expect(payload.toRequest, throwsArgumentError);
    },
  );

  test('strictly parses frozen requests before they can be retried', () {
    final payload = BrokerRequestPayload(
      requestId: '11111111-1111-4111-8111-111111111111',
      consent: const BrokerResearchConsent.approved(
        scope: BrokerConsentScope.imageOnly,
        copyVersion: 'research-consent-v1',
      ),
      derivative: BrokerImageDerivative(
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        longEdgePx: 1600,
      ),
    );
    final request = payload.toRequest();
    final body = jsonEncode(<String, Object?>{'data': request});
    final hash = request['payload_hash']! as String;

    expect(
      isValidFrozenBrokerRequest(
        body: body,
        requestId: payload.requestId,
        payloadHash: hash,
        consent: payload.consent,
      ),
      isTrue,
    );

    final invalidRequests = <Map<String, Object?>>[
      <String, Object?>{...request, 'local_path': '/private/image.jpg'},
      <String, Object?>{
        ...request,
        'image': <String, Object?>{
          ...(request['image']! as Map<String, Object?>),
          'byte_size': 1500001,
        },
      },
      <String, Object?>{
        ...request,
        'image': <String, Object?>{
          ...(request['image']! as Map<String, Object?>),
          'long_edge_px': 1601,
        },
      },
      <String, Object?>{
        ...request,
        'image': <String, Object?>{
          ...(request['image']! as Map<String, Object?>),
          'content_base64': 'AQI=',
        },
      },
    ];
    for (final invalid in invalidRequests) {
      expect(
        isValidFrozenBrokerRequest(
          body: jsonEncode(<String, Object?>{'data': invalid}),
          requestId: payload.requestId,
          payloadHash: hash,
          consent: payload.consent,
        ),
        isFalse,
      );
    }
    expect(
      isValidFrozenBrokerRequest(
        body: body.replaceFirst('research-consent-v1', r'\ud800'),
        requestId: payload.requestId,
        payloadHash: hash,
        consent: payload.consent,
      ),
      isFalse,
    );
  });

  test('rejects present null frozen draft hint optionals', () {
    final payload = BrokerRequestPayload(
      requestId: '11111111-1111-4111-8111-111111111111',
      consent: const BrokerResearchConsent.approved(
        scope: BrokerConsentScope.imagePlusDraftHints,
        copyVersion: 'research-consent-v1',
      ),
      derivative: BrokerImageDerivative(
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        longEdgePx: 1600,
      ),
      draftHints: const BrokerDraftHints(
        titleHint: 'Title',
        artistHint: 'Artist',
        searchTerms: <String>['term'],
      ),
    );
    final request = payload.toRequest();
    final hash = request['payload_hash']! as String;

    for (final key in <String>['title_hint', 'artist_hint', 'search_terms']) {
      final hints = Map<String, Object?>.from(
        request['draft_hints']! as Map<String, Object?>,
      )..[key] = null;
      final invalid = <String, Object?>{...request, 'draft_hints': hints};

      expect(
        isValidFrozenBrokerRequest(
          body: jsonEncode(<String, Object?>{'data': invalid}),
          requestId: payload.requestId,
          payloadHash: hash,
          consent: payload.consent,
        ),
        isFalse,
        reason: key,
      );
    }
  });
}

BrokerConsentScope _scope(String value) {
  return BrokerConsentScope.values.firstWhere(
    (scope) => scope.wireValue == value,
  );
}
