import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/config/app_feature_flags.dart';
import 'package:my_art_collection/app/research/broker_http_client.dart';
import 'package:my_art_collection/app/research/broker_online_research_client.dart';
import 'package:my_art_collection/app/research/broker_payload.dart' as broker;
import 'package:my_art_collection/app/research/firebase_research_runtime.dart';
import 'package:my_art_collection/app/research/image_derivative_service.dart';
import 'package:my_art_collection/app/research/online_research_service.dart';

void main() {
  test(
    'missing consent performs no gate, artwork, image, or network work',
    () async {
      final harness = _Harness();

      await expectLater(
        harness.adapter.research(_request(consent: null)),
        throwsA(
          isA<BrokerResearchFailureException>().having(
            (error) => error.action,
            'action',
            BrokerResearchFailureAction.freshConsent,
          ),
        ),
      );

      harness.expectNoContentOrNetworkWork();
      expect(harness.runtime.calls, isEmpty);
    },
  );

  test(
    'compile-disabled and misconfigured endpoints have zero side effects',
    () async {
      for (final flags in <AppFeatureFlagService>[
        AppFeatureFlagService(
          runtime: _RecordingRuntime(),
          isReleaseMode: true,
          targetPlatform: TargetPlatform.android,
          brokerClientEnabled: false,
          firebaseAndroid: true,
          remoteConfigEnabled: true,
          brokerEndpoint: _Harness.endpoint,
        ),
        AppFeatureFlagService(
          runtime: _RecordingRuntime(),
          isReleaseMode: true,
          targetPlatform: TargetPlatform.android,
          brokerClientEnabled: true,
          firebaseAndroid: true,
          remoteConfigEnabled: true,
          brokerEndpoint: 'https://unapproved.example/research',
        ),
      ]) {
        final harness = _Harness(flags: flags);
        await expectLater(
          harness.adapter.research(_request()),
          throwsA(isA<BrokerResearchFailureException>()),
        );
        harness.expectNoContentOrNetworkWork();
        expect(harness.runtime.calls, isEmpty);
      }
    },
  );

  test(
    'runtime disabled or unavailable stops before artwork and identity work',
    () async {
      for (final runtime in <_RecordingRuntime>[
        _RecordingRuntime(onlineEnabled: false),
        _RecordingRuntime(throwOnRemoteConfig: true),
      ]) {
        final harness = _Harness(runtime: runtime);
        await expectLater(
          harness.adapter.research(_request()),
          throwsA(
            isA<BrokerResearchFailureException>().having(
              (error) => error.code,
              'code',
              'research_disabled',
            ),
          ),
        );

        harness.expectNoContentOrNetworkWork();
        expect(runtime.calls, <String>['firebase', 'remote-config']);
      }
    },
  );

  test(
    'presentation mapping covers every authoritative broker fixture code',
    () async {
      final fixture =
          jsonDecode(
                await File(
                  'backend/broker/fixtures/broker-error-v1.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final cases = (fixture['cases']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final codes = cases.map((entry) => entry['code']! as String).toSet();

      expect(codes, <String>{
        'consent_required',
        'consent_stale',
        'credits_exhausted',
        'forbidden',
        'idempotency_conflict',
        'method_not_allowed',
        'not_entitled',
        'payload_invalid',
        'payload_too_large',
        'rate_limited',
        'request_expired',
        'request_in_flight',
        'request_outcome_unknown',
        'temporarily_unavailable',
        'unauthorized',
        'unsupported_media_type',
        'upstream_failure',
        'upstream_invalid_output',
        'upstream_refusal',
        'upstream_timeout',
      });

      for (final entry in cases) {
        final failure = BrokerClientFailure(
          code: entry['code']! as String,
          message: entry['message']! as String,
          retryable: entry['retryable']! as bool,
        );
        final presentation = BrokerResearchFailureException.fromFailure(
          failure,
          requestId: '11111111-1111-4111-8111-111111111111',
        );
        expect(presentation.collectorMessage, isNotEmpty);
        expect(presentation.collectorMessage, isNot(failure.message));
      }

      expect(
        BrokerResearchFailureException.fromFailure(
          const BrokerClientFailure(
            code: 'request_in_flight',
            message: 'safe',
            retryable: true,
          ),
          requestId: '11111111-1111-4111-8111-111111111111',
        ).action,
        BrokerResearchFailureAction.retrySameRequest,
      );
      for (final code in <String>[
        'idempotency_conflict',
        'request_outcome_unknown',
      ]) {
        final presentation = BrokerResearchFailureException.fromFailure(
          BrokerClientFailure(code: code, message: 'safe'),
          requestId: '11111111-1111-4111-8111-111111111111',
        );
        expect(presentation.action, BrokerResearchFailureAction.none);
        expect(presentation.requestId, isNull);
      }
    },
  );
}

OnlineResearchRequest _request({
  broker.BrokerResearchConsent? consent =
      const broker.BrokerResearchConsent.approved(
        scope: broker.BrokerConsentScope.imagePlusDraftHints,
        copyVersion: 'research-consent-v1',
      ),
}) {
  return OnlineResearchRequest(
    artworkId: 'local-artwork-id',
    consentSummary: 'Test consent.',
    querySummary: 'Test query.',
    consentState: ResearchConsentState.approved,
    brokerConsent: consent,
  );
}

class _Harness {
  _Harness({AppFeatureFlagService? flags, _RecordingRuntime? runtime})
    : runtime = runtime ?? _runtimeFromFlags(flags),
      imageSource = _RecordingImageSource(),
      derivative = _RecordingDerivative(),
      connectivity = _RecordingConnectivity(),
      transport = _RecordingTransport() {
    final effectiveFlags =
        flags ??
        AppFeatureFlagService(
          runtime: this.runtime,
          isReleaseMode: true,
          targetPlatform: TargetPlatform.android,
          brokerClientEnabled: true,
          firebaseAndroid: true,
          remoteConfigEnabled: true,
          brokerEndpoint: endpoint,
        );
    adapter = BrokerOnlineResearchClient(
      imageSource: imageSource,
      derivativeCreator: derivative,
      httpClient: BrokerHttpClient(
        endpoint: Uri.parse(endpoint),
        featureFlags: effectiveFlags,
        firebaseRuntime: this.runtime,
        transport: transport,
        connectivity: connectivity,
        retryStore: _MemoryRetryStore(),
      ),
    );
  }

  static const endpoint = 'https://broker.example.test/research';
  final _RecordingRuntime runtime;
  final _RecordingImageSource imageSource;
  final _RecordingDerivative derivative;
  final _RecordingConnectivity connectivity;
  final _RecordingTransport transport;
  late final BrokerOnlineResearchClient adapter;

  void expectNoContentOrNetworkWork() {
    expect(imageSource.calls, 0);
    expect(derivative.calls, 0);
    expect(connectivity.calls, 0);
    expect(transport.calls, 0);
    expect(runtime.calls, isNot(contains('app-check')));
    expect(runtime.calls, isNot(contains('anonymous-auth')));
  }

  static _RecordingRuntime _runtimeFromFlags(AppFeatureFlagService? flags) =>
      flags?.runtime is _RecordingRuntime
      ? flags!.runtime! as _RecordingRuntime
      : _RecordingRuntime();
}

class _RecordingImageSource implements BrokerResearchImageSource {
  int calls = 0;
  @override
  Future<File?> primaryImage(String artworkId) async {
    calls += 1;
    return null;
  }
}

class _RecordingDerivative implements ResearchImageDerivativeCreator {
  int calls = 0;
  @override
  Future<broker.BrokerImageDerivative> create(File source) {
    calls += 1;
    throw StateError('must not derive');
  }
}

class _RecordingRuntime implements FirebaseResearchRuntime {
  _RecordingRuntime({
    this.onlineEnabled = true,
    this.throwOnRemoteConfig = false,
  });

  final bool onlineEnabled;
  final bool throwOnRemoteConfig;
  final calls = <String>[];

  @override
  Future<void> initializeFirebase() async => calls.add('firebase');
  @override
  Future<bool> fetchOnlineResearchEnabled() async {
    calls.add('remote-config');
    if (throwOnRemoteConfig) throw StateError('unavailable');
    return onlineEnabled;
  }

  @override
  Future<void> initializeAppCheck() async => calls.add('app-check');
  @override
  Future<void> signInAnonymously() async => calls.add('anonymous-auth');
  @override
  String? currentUserId() => null;
  @override
  Future<String?> authToken({required bool forceRefresh}) async => null;
  @override
  Future<String?> limitedUseAppCheckToken({required bool forceRefresh}) async =>
      null;
}

class _RecordingConnectivity implements BrokerConnectivity {
  int calls = 0;
  @override
  Future<bool> isAvailable(Uri endpoint) async {
    calls += 1;
    return false;
  }
}

class _RecordingTransport implements BrokerHttpTransport {
  int calls = 0;
  @override
  Future<BrokerTransportResponse> post({
    required Uri endpoint,
    required Map<String, String> headers,
    required String body,
  }) {
    calls += 1;
    throw StateError('must not send');
  }
}

class _MemoryRetryStore implements BrokerRetryStore {
  @override
  Future<void> clear(String requestId) async {}
  @override
  Future<FrozenBrokerRequest?> read(String requestId) async => null;
  @override
  Future<void> save(FrozenBrokerRequest request) async {}
}
