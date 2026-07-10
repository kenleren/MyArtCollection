import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/config/app_feature_flags.dart';
import 'package:my_art_collection/app/research/broker_http_client.dart';
import 'package:my_art_collection/app/research/broker_payload.dart';
import 'package:my_art_collection/app/research/firebase_research_runtime.dart';

void main() {
  const endpoint = 'https://broker.example.test/research';

  test(
    'fails closed before Firebase work when local capability is off',
    () async {
      final runtime = _RecordingRuntime();
      final transport = _RecordingTransport();
      final client = _client(
        runtime: runtime,
        transport: transport,
        flags: AppFeatureFlagService(
          runtime: runtime,
          isReleaseMode: true,
          targetPlatform: TargetPlatform.android,
          brokerClientEnabled: false,
          firebaseAndroid: true,
          remoteConfigEnabled: true,
          brokerEndpoint: endpoint,
        ),
      );

      final result = await client.submit(_payload());

      expect(result.failure!.code, 'research_disabled');
      expect(runtime.calls, isEmpty);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'orders post-consent Firebase, App Check, Auth, tokens, and one refresh',
    () async {
      final runtime = _RecordingRuntime();
      final transport = _RecordingTransport(
        responses: <Object>[
          const BrokerTransportResponse(statusCode: 401, body: '{}'),
          BrokerTransportResponse(
            statusCode: 200,
            body: jsonEncode(
              _successBody('11111111-1111-4111-8111-111111111111'),
            ),
          ),
        ],
      );
      final store = _MemoryRetryStore();
      final client = _client(
        runtime: runtime,
        transport: transport,
        store: store,
      );

      final result = await client.submit(_payload());

      expect(result.isSuccess, isTrue);
      expect(result.refreshedAfterUnauthorized, isTrue);
      expect(runtime.calls, <String>[
        'firebase',
        'remote-config',
        'app-check',
        'anonymous-auth',
        'auth:false',
        'app-check-token:false',
        'auth:true',
        'app-check-token:true',
      ]);
      expect(transport.requests, hasLength(2));
      expect(transport.requests[0].body, transport.requests[1].body);
      expect(
        transport.requests.map((request) => request.headers['Authorization']),
        <String?>['Bearer auth-false', 'Bearer auth-true'],
      );
      expect(
        transport.requests.map(
          (request) => request.headers['X-Firebase-AppCheck'],
        ),
        <String?>['app-check-false', 'app-check-true'],
      );
      expect(await store.read(_payload().requestId), isNull);
    },
  );

  test(
    'rejects an endpoint that differs from the compiled broker endpoint',
    () async {
      final runtime = _RecordingRuntime();
      final transport = _RecordingTransport();
      final client = BrokerHttpClient(
        endpoint: Uri.parse('https://other.example.test/research'),
        featureFlags: AppFeatureFlagService(
          runtime: runtime,
          isReleaseMode: true,
          targetPlatform: TargetPlatform.android,
          brokerClientEnabled: true,
          firebaseAndroid: true,
          remoteConfigEnabled: true,
          brokerEndpoint: endpoint,
        ),
        firebaseRuntime: runtime,
        transport: transport,
        connectivity: const _FixedConnectivity(true),
        retryStore: _MemoryRetryStore(),
      );

      final result = await client.submit(_payload());

      expect(result.failure!.code, 'endpoint_unavailable');
      expect(runtime.calls, isEmpty);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'fails closed without transport when Remote Config, connectivity, or tokens fail',
    () async {
      final remoteConfigRuntime = _RecordingRuntime(throwOnRemoteConfig: true);
      final remoteConfigTransport = _RecordingTransport();
      final remoteConfigResult = await _client(
        runtime: remoteConfigRuntime,
        transport: remoteConfigTransport,
      ).submit(_payload());
      expect(remoteConfigResult.failure!.code, 'research_disabled');
      expect(remoteConfigTransport.requests, isEmpty);

      final offlineRuntime = _RecordingRuntime();
      final offlineTransport = _RecordingTransport();
      final offlineResult = await _client(
        runtime: offlineRuntime,
        transport: offlineTransport,
        connectivity: const _FixedConnectivity(false),
      ).submit(_payload());
      expect(offlineResult.failure!.code, 'offline');
      expect(offlineTransport.requests, isEmpty);

      final missingTokenRuntime = _RecordingRuntime(initialAuthToken: null);
      final missingTokenTransport = _RecordingTransport();
      final missingTokenResult = await _client(
        runtime: missingTokenRuntime,
        transport: missingTokenTransport,
      ).submit(_payload());
      expect(missingTokenResult.failure!.code, 'token_unavailable');
      expect(missingTokenTransport.requests, isEmpty);
    },
  );

  test(
    'requires matching current typed consent before retry Firebase or network work',
    () async {
      final request = _payload();
      final store = _MemoryRetryStore();
      await store.save(
        FrozenBrokerRequest(
          requestId: request.requestId,
          payloadHash: request.toRequest()['payload_hash']! as String,
          body: jsonEncode(<String, Object?>{'data': request.toRequest()}),
          consent: request.consent,
        ),
      );
      final runtime = _RecordingRuntime();
      final transport = _RecordingTransport();

      final result =
          await _client(
            runtime: runtime,
            transport: transport,
            store: store,
          ).retry(
            request.requestId,
            consent: const BrokerResearchConsent.approved(
              scope: BrokerConsentScope.imagePlusDraftHints,
              copyVersion: 'research-consent-v1',
            ),
          );

      expect(result.failure!.code, 'consent_required');
      expect(runtime.calls, isEmpty);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'rejects a frozen retry whose embedded consent differs before Firebase work',
    () async {
      final request = _payload();
      final requestBody = request.toRequest()
        ..['consent_scope'] = BrokerConsentScope.imagePlusDraftHints.wireValue;
      final store = _MemoryRetryStore();
      await store.save(
        FrozenBrokerRequest(
          requestId: request.requestId,
          payloadHash: request.toRequest()['payload_hash']! as String,
          body: jsonEncode(<String, Object?>{'data': requestBody}),
          consent: request.consent,
        ),
      );
      final runtime = _RecordingRuntime();
      final transport = _RecordingTransport();

      final result = await _client(
        runtime: runtime,
        transport: transport,
        store: store,
      ).retry(request.requestId, consent: request.consent);

      expect(result.failure!.code, 'retry_not_available');
      expect(runtime.calls, isEmpty);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'strictly rejects tampered frozen requests before Firebase or transport work',
    () async {
      final request = _payload();
      final original = request.toRequest();
      final mutations = <Map<String, Object?>>[
        <String, Object?>{...original, 'local_artwork_id': 'must-not-send'},
        <String, Object?>{
          ...original,
          'image': <String, Object?>{
            ...(original['image']! as Map<String, Object?>),
            'content_base64': 'AQI=',
          },
        },
        <String, Object?>{
          ...original,
          'payload_hash':
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        },
      ];

      for (final mutated in mutations) {
        final store = _MemoryRetryStore();
        await store.save(
          FrozenBrokerRequest(
            requestId: request.requestId,
            payloadHash: original['payload_hash']! as String,
            body: jsonEncode(<String, Object?>{'data': mutated}),
            consent: request.consent,
          ),
        );
        final runtime = _RecordingRuntime();
        final transport = _RecordingTransport();

        final result = await _client(
          runtime: runtime,
          transport: transport,
          store: store,
        ).retry(request.requestId, consent: request.consent);

        expect(result.failure!.code, 'retry_not_available');
        expect(runtime.calls, isEmpty);
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'keeps a frozen body for a consent-matched explicit retry and clears it on completion',
    () async {
      final firstRuntime = _RecordingRuntime();
      final store = _MemoryRetryStore();
      final request = _payload();
      final first = _client(
        runtime: firstRuntime,
        transport: _RecordingTransport(
          responses: <Object>[SocketException('down')],
        ),
        store: store,
      );

      final firstResult = await first.submit(request);
      final frozen = await store.read(request.requestId);
      expect(firstResult.failure!.code, 'transport_unavailable');
      expect(frozen, isNotNull);

      final secondTransport = _RecordingTransport(
        responses: <Object>[
          BrokerTransportResponse(
            statusCode: 200,
            body: jsonEncode(_successBody(request.requestId)),
          ),
        ],
      );
      final retryResult = await _client(
        runtime: _RecordingRuntime(),
        transport: secondTransport,
        store: store,
      ).retry(request.requestId, consent: request.consent);

      expect(retryResult.isSuccess, isTrue);
      expect(secondTransport.requests.single.body, frozen!.body);
      expect(await store.read(request.requestId), isNull);
    },
  );

  test(
    'maps typed allowlisted success responses and never returns raw backend data',
    () async {
      final result = await _client(
        runtime: _RecordingRuntime(),
        transport: _RecordingTransport(
          responses: <Object>[
            BrokerTransportResponse(
              statusCode: 200,
              body: jsonEncode(_validResponseFixture()['success']),
            ),
          ],
        ),
      ).submit(_payload());

      expect(result.isSuccess, isTrue);
      expect(result.response, isA<BrokerSuccessResponse>());
      expect(result.response!.sources.single.sourceUrl, startsWith('https://'));
      expect(result.response!.candidateAttributions.single.sourceRefs, <String>[
        'src_fixture',
      ]);

      final replayed = Map<String, Object?>.from(
        _validResponseFixture()['success']! as Map,
      )..['replayed'] = true;
      final replayedResult = await _client(
        runtime: _RecordingRuntime(),
        transport: _RecordingTransport(
          responses: <Object>[
            BrokerTransportResponse(
              statusCode: 200,
              body: jsonEncode(replayed),
            ),
          ],
        ),
      ).submit(_payload());
      expect(replayedResult.response!.replayed, isTrue);
    },
  );

  test(
    'rejects negative response fixtures and maps only authoritative broker-error-v1 envelopes',
    () async {
      final fixture = _validResponseFixture();
      for (final invalid in fixture['invalid']! as List<Object?>) {
        final malformed = await _client(
          runtime: _RecordingRuntime(),
          transport: _RecordingTransport(
            responses: <Object>[
              BrokerTransportResponse(
                statusCode: 200,
                body: jsonEncode(invalid),
              ),
            ],
          ),
        ).submit(_payload());
        expect(malformed.failure!.code, 'invalid_broker_response');
      }

      final errorFixture =
          jsonDecode(
                await File(
                  'backend/broker/fixtures/broker-error-v1.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      for (final errorCase in errorFixture['cases']! as List<Object?>) {
        final current = Map<String, Object?>.from(errorCase! as Map);
        final code = current['code']! as String;
        final error = <String, Object?>{
          'code': code,
          'message': current['message'],
          'retryable': current['retryable'],
          if (current.containsKey('retry_after_seconds'))
            'retry_after_seconds': current['retry_after_seconds'],
        };
        final result = await _client(
          runtime: _RecordingRuntime(),
          transport: _RecordingTransport(
            responses: _errorResponses(current, error, code),
          ),
        ).submit(_payload());
        expect(result.failure!.code, code);
        expect(result.failure!.message, 'Research is temporarily unavailable.');
      }

      final diagnostic = await _client(
        runtime: _RecordingRuntime(),
        transport: _RecordingTransport(
          responses: <Object>[
            BrokerTransportResponse(
              statusCode: 429,
              body: jsonEncode(<String, Object?>{
                'ok': false,
                'error_contract_version': 'broker-error-v1',
                'status': 'rejected',
                'error': <String, Object?>{
                  'code': 'rate_limited',
                  'message': 'provider diagnostic must not reach the collector',
                  'retryable': true,
                  'retry_after_seconds': 30,
                },
              }),
            ),
          ],
        ),
      ).submit(_payload());
      expect(diagnostic.failure!.code, 'invalid_broker_response');

      final validRateLimit = <String, Object?>{
        'ok': false,
        'error_contract_version': 'broker-error-v1',
        'request_id': _payload().requestId,
        'status': 'rejected',
        'error': <String, Object?>{
          'code': 'rate_limited',
          'message': 'The research service is busy. Try again later.',
          'retryable': true,
          'retry_after_seconds': 30,
        },
      };
      final crossProductBodies = <Map<String, Object?>>[
        validRateLimit,
        <String, Object?>{...validRateLimit, 'status': 'conflict'},
        <String, Object?>{
          ...validRateLimit,
          'error': <String, Object?>{
            ...(validRateLimit['error']! as Map<String, Object?>),
            'retry_after_seconds': 5,
          },
        },
      ];
      final crossProductStatuses = <int>[503, 429, 429];
      for (var index = 0; index < crossProductBodies.length; index += 1) {
        final result = await _client(
          runtime: _RecordingRuntime(),
          transport: _RecordingTransport(
            responses: <Object>[
              BrokerTransportResponse(
                statusCode: crossProductStatuses[index],
                body: jsonEncode(crossProductBodies[index]),
              ),
            ],
          ),
        ).submit(_payload());
        expect(result.failure!.code, 'invalid_broker_response');
      }
    },
  );

  test(
    'file retry storage survives reopen and only accepts UUID request IDs',
    () async {
      final root = await Directory.systemTemp.createTemp('broker-retry-store-');
      addTearDown(() => root.delete(recursive: true));
      const requestId = '11111111-1111-4111-8111-111111111111';
      final first = await FileBrokerRetryStore.openAt(root);
      await first.save(
        const FrozenBrokerRequest(
          requestId: requestId,
          payloadHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          body: '{"data":{}}',
          consent: BrokerResearchConsent.approved(
            scope: BrokerConsentScope.imageOnly,
            copyVersion: 'research-consent-v1',
          ),
        ),
      );

      final second = await FileBrokerRetryStore.openAt(root);
      final restored = await second.read(requestId);
      expect(restored!.payloadHash, hasLength(64));
      expect(restored.body, '{"data":{}}');
      expect(restored.consent.scope, BrokerConsentScope.imageOnly);
      expect(() => second.read('not-a-uuid'), throwsArgumentError);
    },
  );
}

BrokerHttpClient _client({
  required _RecordingRuntime runtime,
  required _RecordingTransport transport,
  AppFeatureFlagService? flags,
  BrokerConnectivity connectivity = const _FixedConnectivity(true),
  BrokerRetryStore? store,
}) {
  return BrokerHttpClient(
    endpoint: Uri.parse('https://broker.example.test/research'),
    featureFlags:
        flags ??
        AppFeatureFlagService(
          runtime: runtime,
          isReleaseMode: true,
          targetPlatform: TargetPlatform.android,
          brokerClientEnabled: true,
          firebaseAndroid: true,
          remoteConfigEnabled: true,
          brokerEndpoint: 'https://broker.example.test/research',
        ),
    firebaseRuntime: runtime,
    transport: transport,
    connectivity: connectivity,
    retryStore: store ?? _MemoryRetryStore(),
  );
}

BrokerRequestPayload _payload() {
  return BrokerRequestPayload(
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
}

Map<String, Object?> _successBody(String requestId) => <String, Object?>{
  'request_id': requestId,
  'status': 'completed',
  'provider': 'fake-provider',
  'model': 'test',
  'reasoning_effort': 'none',
  'completed_at': '2026-07-10T12:00:00.000Z',
  'sources': const <Object?>[],
  'candidate_attributions': const <Object?>[],
  'comparable_value_signals': const <Object?>[],
  'warnings': const <Object?>[],
};

Map<String, Object?> _validResponseFixture() =>
    jsonDecode(File('test/fixtures/broker-response-v1.json').readAsStringSync())
        as Map<String, Object?>;

bool _isConflictCode(String code) =>
    code == 'idempotency_conflict' ||
    code == 'request_in_flight' ||
    code == 'request_expired' ||
    code == 'request_outcome_unknown';

List<Object> _errorResponses(
  Map<String, Object?> errorCase,
  Map<String, Object?> error,
  String code,
) {
  final response = BrokerTransportResponse(
    statusCode: errorCase['http_status']! as int,
    body: jsonEncode(<String, Object?>{
      'ok': false,
      'error_contract_version': 'broker-error-v1',
      'request_id': _payload().requestId,
      'status': _isConflictCode(code) ? 'conflict' : 'rejected',
      'error': error,
    }),
  );
  return response.statusCode == 401
      ? <Object>[response, response]
      : <Object>[response];
}

class _RecordingRuntime implements FirebaseResearchRuntime {
  _RecordingRuntime({
    this.throwOnRemoteConfig = false,
    this.initialAuthToken = 'auth',
  });

  final bool throwOnRemoteConfig;
  final String? initialAuthToken;
  final calls = <String>[];

  @override
  Future<String?> authToken({required bool forceRefresh}) async {
    calls.add('auth:$forceRefresh');
    return initialAuthToken == null ? null : 'auth-$forceRefresh';
  }

  @override
  Future<bool> fetchOnlineResearchEnabled() async {
    calls.add('remote-config');
    if (throwOnRemoteConfig) {
      throw StateError('Remote Config unavailable');
    }
    return true;
  }

  @override
  Future<void> initializeAppCheck() async => calls.add('app-check');

  @override
  Future<void> initializeFirebase() async => calls.add('firebase');

  @override
  Future<String?> limitedUseAppCheckToken({required bool forceRefresh}) async {
    calls.add('app-check-token:$forceRefresh');
    return 'app-check-$forceRefresh';
  }

  @override
  Future<void> signInAnonymously() async => calls.add('anonymous-auth');
}

class _RecordingTransport implements BrokerHttpTransport {
  _RecordingTransport({List<Object> responses = const <Object>[]})
    : responses = List<Object>.of(responses);

  final List<Object> responses;
  final requests = <_TransportRequest>[];

  @override
  Future<BrokerTransportResponse> post({
    required Uri endpoint,
    required Map<String, String> headers,
    required String body,
  }) async {
    requests.add(_TransportRequest(headers: Map.of(headers), body: body));
    if (responses.isEmpty) {
      throw StateError('No test response was configured.');
    }
    final response = responses.removeAt(0);
    if (response case final BrokerTransportResponse transportResponse) {
      return transportResponse;
    }
    throw response;
  }
}

class _TransportRequest {
  const _TransportRequest({required this.headers, required this.body});

  final Map<String, String> headers;
  final String body;
}

class _MemoryRetryStore implements BrokerRetryStore {
  final values = <String, FrozenBrokerRequest>{};

  @override
  Future<void> clear(String requestId) async {
    values.remove(requestId);
  }

  @override
  Future<FrozenBrokerRequest?> read(String requestId) async =>
      values[requestId];

  @override
  Future<void> save(FrozenBrokerRequest request) async {
    values[request.requestId] = request;
  }
}

class _FixedConnectivity implements BrokerConnectivity {
  const _FixedConnectivity(this.available);

  final bool available;

  @override
  Future<bool> isAvailable(Uri endpoint) async => available;
}
