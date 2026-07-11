import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';

/// Firebase operations needed by the consent-gated research client.
///
/// Nothing in this interface is called from application startup. Keeping the
/// calls here makes the required Firebase, Remote Config, App Check, and Auth
/// ordering explicit and injectable for focused tests.
abstract interface class FirebaseResearchRuntime {
  Future<void> initializeFirebase();

  Future<bool> fetchOnlineResearchEnabled();

  Future<void> initializeAppCheck();

  Future<void> signInAnonymously();

  Future<String?> authToken({required bool forceRefresh});

  Future<String?> limitedUseAppCheckToken({required bool forceRefresh});
}

class FlutterFirebaseResearchRuntime implements FirebaseResearchRuntime {
  FlutterFirebaseResearchRuntime({
    FirebaseAuth? auth,
    FirebaseAppCheck? appCheck,
    FirebaseRemoteConfig? remoteConfig,
  }) : _authOverride = auth,
       _appCheckOverride = appCheck,
       _remoteConfigOverride = remoteConfig;

  final FirebaseAuth? _authOverride;
  final FirebaseAppCheck? _appCheckOverride;
  final FirebaseRemoteConfig? _remoteConfigOverride;
  bool _firebaseInitialized = false;
  bool _appCheckInitialized = false;

  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseAppCheck get _appCheck =>
      _appCheckOverride ?? FirebaseAppCheck.instance;
  FirebaseRemoteConfig get _remoteConfig =>
      _remoteConfigOverride ?? FirebaseRemoteConfig.instance;

  @override
  Future<void> initializeFirebase() async {
    if (_firebaseInitialized) {
      return;
    }
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    _firebaseInitialized = true;
  }

  @override
  Future<bool> fetchOnlineResearchEnabled() async {
    await _requireFirebase();
    await _remoteConfig.setConfigSettings(
      RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval: const Duration(hours: 1),
      ),
    );
    await _remoteConfig.setDefaults(const <String, Object>{
      'online_research_enabled': false,
    });
    await _remoteConfig.fetchAndActivate();
    return _remoteConfig.getBool('online_research_enabled');
  }

  @override
  Future<void> initializeAppCheck() async {
    await _requireFirebase();
    if (_appCheckInitialized) {
      return;
    }
    await _appCheck.activate(
      providerAndroid: const AndroidPlayIntegrityProvider(),
    );
    _appCheckInitialized = true;
  }

  @override
  Future<void> signInAnonymously() async {
    await _requireFirebase();
    if (_auth.currentUser != null) {
      return;
    }
    await _auth.signInAnonymously();
  }

  @override
  Future<String?> authToken({required bool forceRefresh}) async {
    await _requireFirebase();
    return _auth.currentUser?.getIdToken(forceRefresh);
  }

  @override
  Future<String?> limitedUseAppCheckToken({required bool forceRefresh}) async {
    await _requireFirebase();
    return _appCheck.getLimitedUseToken();
  }

  Future<void> _requireFirebase() {
    if (!_firebaseInitialized) {
      throw StateError(
        'Firebase research runtime was used before initialization.',
      );
    }
    return Future<void>.value();
  }
}
