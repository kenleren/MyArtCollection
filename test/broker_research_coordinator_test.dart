import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/config/app_feature_flags.dart';
import 'package:my_art_collection/app/research/broker_http_client.dart';
import 'package:my_art_collection/app/research/broker_payload.dart';
import 'package:my_art_collection/app/research/broker_research_coordinator.dart';
import 'package:my_art_collection/app/research/firebase_research_runtime.dart';
import 'package:my_art_collection/app/research/image_derivative_service.dart';

void main() {
  test(
    'does not read or derive a source image before current typed consent',
    () async {
      final derivative = _RecordingDerivativeCreator();
      final client = _client();
      final coordinator = BrokerResearchCoordinator(
        consentProvider: const _FixedConsentProvider(null),
        derivativeCreator: derivative,
        client: client,
      );

      final result = await coordinator.submitSource(
        source: File('/definitely-not-read-without-consent.jpg'),
        authorization: await _authorization(client),
      );

      expect(result.failure!.code, 'consent_required');
      expect(derivative.sources, isEmpty);
    },
  );

  test('fails closed without image access when consent lookup fails', () async {
    final derivative = _RecordingDerivativeCreator();
    final client = _client();
    final coordinator = BrokerResearchCoordinator(
      consentProvider: const _ThrowingConsentProvider(),
      derivativeCreator: derivative,
      client: client,
    );

    final result = await coordinator.submitSource(
      source: File('/definitely-not-read-on-consent-error.jpg'),
      authorization: await _authorization(client),
    );

    expect(result.failure!.code, 'consent_required');
    expect(derivative.sources, isEmpty);
  });

  test('derives only after current typed consent is approved', () async {
    final derivative = _RecordingDerivativeCreator();
    final client = _client();
    final coordinator = BrokerResearchCoordinator(
      consentProvider: const _FixedConsentProvider(
        BrokerResearchConsent.approved(
          scope: BrokerConsentScope.imageOnly,
          copyVersion: 'research-consent-v1',
        ),
      ),
      derivativeCreator: derivative,
      client: client,
    );

    final result = await coordinator.submitSource(
      source: File('/current-consent-permits-derivative.jpg'),
      authorization: await _authorization(client),
    );

    expect(
      derivative.sources.single.path,
      '/current-consent-permits-derivative.jpg',
    );
    expect(result.failure!.code, 'offline');
  });
}

class _FixedConsentProvider implements BrokerResearchConsentProvider {
  const _FixedConsentProvider(this.value);

  final BrokerResearchConsent? value;

  @override
  Future<BrokerResearchConsent?> currentApprovedConsent() async => value;
}

class _ThrowingConsentProvider implements BrokerResearchConsentProvider {
  const _ThrowingConsentProvider();

  @override
  Future<BrokerResearchConsent?> currentApprovedConsent() =>
      throw StateError('consent storage unavailable');
}

class _RecordingDerivativeCreator implements ResearchImageDerivativeCreator {
  final sources = <File>[];

  @override
  Future<BrokerImageDerivative> create(File source) async {
    sources.add(source);
    return BrokerImageDerivative(
      bytes: Uint8List.fromList(<int>[1]),
      longEdgePx: 1,
    );
  }
}

BrokerHttpClient _client() => BrokerHttpClient(
  endpoint: Uri.parse('https://broker.example.test/research'),
  featureFlags: const AppFeatureFlagService(
    runtime: _NoopRuntime(),
    isReleaseMode: true,
    targetPlatform: TargetPlatform.android,
    brokerClientEnabled: true,
    firebaseAndroid: true,
    remoteConfigEnabled: true,
    brokerEndpoint: 'https://broker.example.test/research',
  ),
  firebaseRuntime: const _NoopRuntime(),
  transport: const _NoopTransport(),
  connectivity: const _NoopConnectivity(),
  retryStore: const _NoopRetryStore(),
);

Future<BrokerResearchAuthorization> _authorization(
  BrokerHttpClient client,
) async {
  final gate = await client.authorizeAfterConsent();
  return gate.authorization!;
}

class _NoopRuntime implements FirebaseResearchRuntime {
  const _NoopRuntime();

  @override
  String? currentUserId() => null;

  @override
  Future<String?> authToken({required bool forceRefresh}) async => null;

  @override
  Future<bool> fetchOnlineResearchEnabled() async => true;

  @override
  Future<void> initializeAppCheck() async {}

  @override
  Future<void> initializeFirebase() async {}

  @override
  Future<String?> limitedUseAppCheckToken({required bool forceRefresh}) async =>
      null;

  @override
  Future<void> signInAnonymously() async {}
}

class _NoopTransport implements BrokerHttpTransport {
  const _NoopTransport();

  @override
  Future<BrokerTransportResponse> post({
    required Uri endpoint,
    required Map<String, String> headers,
    required String body,
  }) => throw UnimplementedError();
}

class _NoopConnectivity implements BrokerConnectivity {
  const _NoopConnectivity();

  @override
  Future<bool> isAvailable(Uri endpoint) async => false;
}

class _NoopRetryStore implements BrokerRetryStore {
  const _NoopRetryStore();

  @override
  Future<void> clear(String requestId) async {}

  @override
  Future<FrozenBrokerRequest?> read(String requestId) async => null;

  @override
  Future<void> save(FrozenBrokerRequest request) async {}
}
