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
    'missing consent resolves no source, derivative, identity, or network',
    () async {
      final derivative = _RecordingDerivativeCreator();
      final runtime = _RecordingRuntime();
      var sourceReads = 0;
      final coordinator = BrokerResearchCoordinator(
        derivativeCreator: derivative,
        client: _client(runtime),
      );

      final result = await coordinator.submitSource(
        consent: null,
        resolveSource: () async {
          sourceReads += 1;
          return File('/must-not-be-resolved.jpg');
        },
      );

      expect(result.failure!.code, 'consent_required');
      expect(sourceReads, 0);
      expect(derivative.sources, isEmpty);
      expect(runtime.calls, isEmpty);
    },
  );

  test('runtime gate failure resolves no source or derivative', () async {
    final derivative = _RecordingDerivativeCreator();
    final runtime = _RecordingRuntime(onlineEnabled: false);
    var sourceReads = 0;
    final coordinator = BrokerResearchCoordinator(
      derivativeCreator: derivative,
      client: _client(runtime),
    );

    final result = await coordinator.submitSource(
      consent: _consent,
      requestId: _requestId,
      resolveSource: () async {
        sourceReads += 1;
        return File('/must-not-be-resolved.jpg');
      },
    );

    expect(result.failure!.code, 'research_disabled');
    expect(sourceReads, 0);
    expect(derivative.sources, isEmpty);
    expect(runtime.calls, <String>['firebase', 'remote-config']);
  });

  test('derives only after consent and both gates pass', () async {
    final derivative = _RecordingDerivativeCreator();
    final runtime = _RecordingRuntime();
    final coordinator = BrokerResearchCoordinator(
      derivativeCreator: derivative,
      client: _client(runtime),
    );

    final result = await coordinator.submitSource(
      consent: _consent,
      requestId: _requestId,
      resolveSource: () async =>
          File('/current-consent-permits-derivative.jpg'),
    );

    expect(
      derivative.sources.single.path,
      '/current-consent-permits-derivative.jpg',
    );
    expect(result.failure!.code, 'offline');
  });
}

const _requestId = '11111111-1111-4111-8111-111111111111';
const _consent = BrokerResearchConsent.approved(
  scope: BrokerConsentScope.imageOnly,
  copyVersion: 'research-consent-v1',
);

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

BrokerHttpClient _client(_RecordingRuntime runtime) => BrokerHttpClient(
  endpoint: Uri.parse('https://broker.example.test/research'),
  featureFlags: AppFeatureFlagService(
    runtime: runtime,
    isReleaseMode: true,
    targetPlatform: TargetPlatform.android,
    brokerClientEnabled: true,
    firebaseAndroid: true,
    remoteConfigEnabled: true,
    brokerEndpoint: 'https://broker.example.test/research',
  ),
  firebaseRuntime: runtime,
  transport: const _NoopTransport(),
  connectivity: const _NoopConnectivity(),
  retryStore: const _NoopRetryStore(),
);

class _RecordingRuntime implements FirebaseResearchRuntime {
  _RecordingRuntime({this.onlineEnabled = true});

  final bool onlineEnabled;
  final calls = <String>[];

  @override
  String? currentUserId() => null;

  @override
  Future<String?> authToken({required bool forceRefresh}) async => null;

  @override
  Future<bool> fetchOnlineResearchEnabled() async {
    calls.add('remote-config');
    return onlineEnabled;
  }

  @override
  Future<void> initializeAppCheck() async => calls.add('app-check');

  @override
  Future<void> initializeFirebase() async => calls.add('firebase');

  @override
  Future<String?> limitedUseAppCheckToken({required bool forceRefresh}) async =>
      null;

  @override
  Future<void> signInAnonymously() async => calls.add('anonymous-auth');
}

class _NoopTransport implements BrokerHttpTransport {
  const _NoopTransport();

  @override
  Future<BrokerTransportResponse> post({
    required Uri endpoint,
    required Map<String, String> headers,
    required String body,
  }) => throw StateError('transport must not run');
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
