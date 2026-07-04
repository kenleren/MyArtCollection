import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

const _firebaseAndroidDefine = bool.fromEnvironment(
  'MY_ART_COLLECTION_FIREBASE_ANDROID',
);
const _remoteConfigDefine = bool.fromEnvironment(
  'MY_ART_COLLECTION_REMOTE_CONFIG',
);

class AppFeatureFlags {
  const AppFeatureFlags({this.onlineResearchEnabled = false});

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

abstract interface class AppFeatureFlagBackend {
  Future<bool> onlineResearchEnabled();
}

class FirebaseRemoteConfigAppFeatureFlagBackend
    implements AppFeatureFlagBackend {
  const FirebaseRemoteConfigAppFeatureFlagBackend();

  @override
  Future<bool> onlineResearchEnabled() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }

    final remoteConfig = FirebaseRemoteConfig.instance;
    await remoteConfig.setConfigSettings(
      RemoteConfigSettings(
        fetchTimeout: Duration(seconds: 10),
        minimumFetchInterval: Duration(hours: 1),
      ),
    );
    await remoteConfig.setDefaults(AppFeatureFlagDefaults.values);
    await remoteConfig.fetchAndActivate();
    return remoteConfig.getBool(AppFeatureFlagKeys.onlineResearchEnabled);
  }
}

class AppFeatureFlagService {
  const AppFeatureFlagService({
    AppFeatureFlagBackend? backend,
    this.isReleaseMode = kReleaseMode,
    this.targetPlatform,
    this.firebaseAndroid = _firebaseAndroidDefine,
    this.remoteConfigEnabled = _remoteConfigDefine,
  }) : _backend = backend ?? const FirebaseRemoteConfigAppFeatureFlagBackend();

  final AppFeatureFlagBackend _backend;
  final bool isReleaseMode;
  final TargetPlatform? targetPlatform;
  final bool firebaseAndroid;
  final bool remoteConfigEnabled;

  Future<AppFeatureFlags> load() async {
    final effectiveTargetPlatform = targetPlatform ?? defaultTargetPlatform;
    final shouldFetchRemoteConfig =
        isReleaseMode &&
        effectiveTargetPlatform == TargetPlatform.android &&
        firebaseAndroid &&
        remoteConfigEnabled;

    if (!shouldFetchRemoteConfig) {
      return const AppFeatureFlags();
    }

    try {
      return AppFeatureFlags(
        onlineResearchEnabled: await _backend.onlineResearchEnabled(),
      );
    } on Object {
      return const AppFeatureFlags();
    }
  }
}
