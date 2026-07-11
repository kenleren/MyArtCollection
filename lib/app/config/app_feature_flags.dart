import 'package:flutter/foundation.dart';

import '../research/firebase_research_runtime.dart';

const _brokerClientDefine = bool.fromEnvironment(
  'MY_ART_COLLECTION_BROKER_CLIENT',
);
const _firebaseAndroidDefine = bool.fromEnvironment(
  'MY_ART_COLLECTION_FIREBASE_ANDROID',
);
const _remoteConfigDefine = bool.fromEnvironment(
  'MY_ART_COLLECTION_REMOTE_CONFIG',
);
const _brokerEndpointDefine = String.fromEnvironment(
  'MY_ART_COLLECTION_BROKER_ENDPOINT',
);

/// Closed endpoint set for #188. A live Function URL must be added here only
/// after #155 approves the deployment target and release gate.
enum ArchivaleBrokerEndpoint {
  test('https://broker.example.test/research'),
  artifactInspection('https://broker.example.invalid/research');

  const ArchivaleBrokerEndpoint(this.wireValue);

  final String wireValue;
}

final _approvedBrokerEndpoints = ArchivaleBrokerEndpoint.values
    .map((endpoint) => endpoint.wireValue)
    .toSet();

bool isApprovedArchivaleBrokerEndpoint(Uri endpoint) {
  return _approvedBrokerEndpoints.contains(endpoint.toString());
}

class AppFeatureFlags {
  const AppFeatureFlags({
    this.localResearchCapabilityEnabled = false,
    this.onlineResearchEnabled = false,
  });

  /// This local gate controls whether consent UI may be offered. It is never
  /// backed by Firebase and defaults to false in every artifact.
  final bool localResearchCapabilityEnabled;
  final bool onlineResearchEnabled;
}

class AppFeatureFlagKeys {
  static const onlineResearchEnabled = 'online_research_enabled';

  static const Set<String> allowlist = {onlineResearchEnabled};
}

class AppFeatureFlagDefaults {
  static const values = <String, Object>{
    AppFeatureFlagKeys.onlineResearchEnabled: false,
  };
}

class AppFeatureFlagService {
  const AppFeatureFlagService({
    this.runtime,
    this.isReleaseMode = kReleaseMode,
    this.targetPlatform,
    this.brokerClientEnabled = _brokerClientDefine,
    this.firebaseAndroid = _firebaseAndroidDefine,
    this.remoteConfigEnabled = _remoteConfigDefine,
    this.brokerEndpoint = _brokerEndpointDefine,
  });

  final FirebaseResearchRuntime? runtime;
  final bool isReleaseMode;
  final TargetPlatform? targetPlatform;
  final bool brokerClientEnabled;
  final bool firebaseAndroid;
  final bool remoteConfigEnabled;
  final String brokerEndpoint;

  Uri? get _configuredBrokerEndpoint {
    if (!_approvedBrokerEndpoints.contains(brokerEndpoint)) {
      return null;
    }
    final endpoint = Uri.tryParse(brokerEndpoint);
    if (endpoint == null || endpoint.toString() != brokerEndpoint) {
      return null;
    }
    return endpoint;
  }

  bool get localResearchCapabilityEnabled {
    final endpoint = _configuredBrokerEndpoint;
    final effectiveTargetPlatform = targetPlatform ?? defaultTargetPlatform;
    return isReleaseMode &&
        effectiveTargetPlatform == TargetPlatform.android &&
        brokerClientEnabled &&
        firebaseAndroid &&
        remoteConfigEnabled &&
        endpoint != null;
  }

  AppFeatureFlags localFlags() {
    return AppFeatureFlags(
      localResearchCapabilityEnabled: localResearchCapabilityEnabled,
    );
  }

  /// A broker client may only use the HTTPS endpoint compiled into its artifact.
  bool isConfiguredBrokerEndpoint(Uri endpoint) {
    final configured = _configuredBrokerEndpoint;
    return configured != null && endpoint.toString() == configured.toString();
  }

  /// Must only be called after confirmed typed research consent. This is the
  /// first point at which the client is allowed to initialize Firebase or read
  /// Remote Config.
  Future<AppFeatureFlags> loadAfterConsent() async {
    final activeRuntime = runtime;
    if (!localResearchCapabilityEnabled || activeRuntime == null) {
      return localFlags();
    }

    try {
      await activeRuntime.initializeFirebase();
      return AppFeatureFlags(
        localResearchCapabilityEnabled: true,
        onlineResearchEnabled: await activeRuntime.fetchOnlineResearchEnabled(),
      );
    } on Object {
      return localFlags();
    }
  }
}
