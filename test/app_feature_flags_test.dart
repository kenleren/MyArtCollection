import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/config/app_feature_flags.dart';
import 'package:my_art_collection/app/research/firebase_research_runtime.dart';

void main() {
  test(
    'local research capability defaults to disabled without Firebase work',
    () {
      const service = AppFeatureFlagService(
        isReleaseMode: true,
        targetPlatform: TargetPlatform.android,
      );

      expect(service.localResearchCapabilityEnabled, isFalse);
      expect(service.localFlags().localResearchCapabilityEnabled, isFalse);
      expect(service.localFlags().onlineResearchEnabled, isFalse);
    },
  );

  test(
    'post-consent flag evaluation initializes Firebase before Remote Config',
    () async {
      final runtime = _RecordingRuntime(remoteConfigEnabled: true);
      final service = AppFeatureFlagService(
        runtime: runtime,
        isReleaseMode: true,
        targetPlatform: TargetPlatform.android,
        brokerClientEnabled: true,
        firebaseAndroid: true,
        remoteConfigEnabled: true,
        brokerEndpoint: 'https://broker.example.test/research',
      );

      expect(
        runtime.calls,
        isEmpty,
        reason: 'Startup must not touch Firebase.',
      );

      final flags = await service.loadAfterConsent();

      expect(flags.localResearchCapabilityEnabled, isTrue);
      expect(flags.onlineResearchEnabled, isTrue);
      expect(runtime.calls, ['firebase', 'remote-config']);
    },
  );

  test(
    'attacker HTTPS broker endpoint keeps Android local capability disabled',
    () async {
      final runtime = _RecordingRuntime(remoteConfigEnabled: true);
      final service = AppFeatureFlagService(
        runtime: runtime,
        isReleaseMode: true,
        targetPlatform: TargetPlatform.android,
        brokerClientEnabled: true,
        firebaseAndroid: true,
        remoteConfigEnabled: true,
        brokerEndpoint: 'https://attacker.example/research',
      );

      expect(service.localResearchCapabilityEnabled, isFalse);
      expect(
        service.isConfiguredBrokerEndpoint(
          Uri.parse('https://attacker.example/research'),
        ),
        isFalse,
      );

      final flags = await service.loadAfterConsent();

      expect(flags.localResearchCapabilityEnabled, isFalse);
      expect(flags.onlineResearchEnabled, isFalse);
      expect(runtime.calls, isEmpty);
    },
  );

  test('broker endpoint allowlist requires an exact URI', () {
    for (final endpoint in <String>[
      'https://broker.example.test:443/research',
      'https://broker.example.test/research/',
      'https://broker.example.test/research?debug=true',
    ]) {
      final service = AppFeatureFlagService(
        runtime: _RecordingRuntime(remoteConfigEnabled: true),
        isReleaseMode: true,
        targetPlatform: TargetPlatform.android,
        brokerClientEnabled: true,
        firebaseAndroid: true,
        remoteConfigEnabled: true,
        brokerEndpoint: endpoint,
      );

      expect(service.localResearchCapabilityEnabled, isFalse, reason: endpoint);
      expect(
        service.isConfiguredBrokerEndpoint(Uri.parse(endpoint)),
        isFalse,
        reason: endpoint,
      );
    }
  });

  test('Remote Config errors fail closed after consent', () async {
    final runtime = _RecordingRuntime(throwOnRemoteConfig: true);
    final service = AppFeatureFlagService(
      runtime: runtime,
      isReleaseMode: true,
      targetPlatform: TargetPlatform.android,
      brokerClientEnabled: true,
      firebaseAndroid: true,
      remoteConfigEnabled: true,
      brokerEndpoint: 'https://broker.example.test/research',
    );

    final flags = await service.loadAfterConsent();

    expect(flags.localResearchCapabilityEnabled, isTrue);
    expect(flags.onlineResearchEnabled, isFalse);
    expect(runtime.calls, ['firebase', 'remote-config']);
  });

  test(
    'missing compile-time gate does not initialize Firebase after consent',
    () async {
      final runtime = _RecordingRuntime(remoteConfigEnabled: true);
      final service = AppFeatureFlagService(
        runtime: runtime,
        isReleaseMode: true,
        targetPlatform: TargetPlatform.android,
        brokerClientEnabled: false,
        firebaseAndroid: true,
        remoteConfigEnabled: true,
        brokerEndpoint: 'https://broker.example.test/research',
      );

      final flags = await service.loadAfterConsent();

      expect(flags.localResearchCapabilityEnabled, isFalse);
      expect(flags.onlineResearchEnabled, isFalse);
      expect(runtime.calls, isEmpty);
    },
  );
}

class _RecordingRuntime implements FirebaseResearchRuntime {
  _RecordingRuntime({
    this.remoteConfigEnabled = false,
    this.throwOnRemoteConfig = false,
  });

  final bool remoteConfigEnabled;
  final bool throwOnRemoteConfig;
  final calls = <String>[];

  @override
  String? currentUserId() => 'test-user';

  @override
  Future<String?> authToken({required bool forceRefresh}) async => 'auth-token';

  @override
  Future<bool> fetchOnlineResearchEnabled() async {
    calls.add('remote-config');
    if (throwOnRemoteConfig) {
      throw StateError('Remote Config unavailable');
    }
    return remoteConfigEnabled;
  }

  @override
  Future<void> initializeAppCheck() async {
    calls.add('app-check');
  }

  @override
  Future<void> initializeFirebase() async {
    calls.add('firebase');
  }

  @override
  Future<String?> limitedUseAppCheckToken({required bool forceRefresh}) async =>
      'app-check-token';

  @override
  Future<void> signInAnonymously() async {
    calls.add('anonymous-auth');
  }
}
