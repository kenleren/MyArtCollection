import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

const _internalBetaCrashlyticsDefine = bool.fromEnvironment(
  'MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS',
);
const _crashlyticsTestCrashDefine = bool.fromEnvironment(
  'MY_ART_COLLECTION_CRASHLYTICS_TEST_CRASH',
);

class CrashTelemetryConfig {
  const CrashTelemetryConfig({
    required this.collectionEnabled,
    required this.initializeFirebase,
    required this.forceTestCrashOnStartup,
  });

  factory CrashTelemetryConfig.fromEnvironment({
    bool isReleaseMode = kReleaseMode,
    bool internalBetaCrashlytics = _internalBetaCrashlyticsDefine,
    bool crashlyticsTestCrash = _crashlyticsTestCrashDefine,
  }) {
    final collectionEnabled = isReleaseMode && internalBetaCrashlytics;
    return CrashTelemetryConfig(
      collectionEnabled: collectionEnabled,
      initializeFirebase: collectionEnabled,
      forceTestCrashOnStartup: collectionEnabled && crashlyticsTestCrash,
    );
  }

  final bool collectionEnabled;
  final bool initializeFirebase;
  final bool forceTestCrashOnStartup;
}

abstract interface class CrashTelemetryBackend {
  Future<void> initializeFirebase();

  Future<void> setCrashlyticsCollectionEnabled(bool enabled);

  Future<void> recordError(
    Object error,
    StackTrace stack, {
    required bool fatal,
    required String reason,
  });

  void crash();
}

class FirebaseCrashTelemetryBackend implements CrashTelemetryBackend {
  FirebaseCrashTelemetryBackend();

  bool _firebaseInitialized = false;

  @override
  Future<void> initializeFirebase() async {
    if (_firebaseInitialized) {
      return;
    }
    await Firebase.initializeApp();
    _firebaseInitialized = true;
  }

  @override
  Future<void> setCrashlyticsCollectionEnabled(bool enabled) {
    return FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
      enabled,
    );
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace stack, {
    required bool fatal,
    required String reason,
  }) {
    return FirebaseCrashlytics.instance.recordError(
      error,
      stack,
      fatal: fatal,
      reason: reason,
    );
  }

  @override
  void crash() {
    FirebaseCrashlytics.instance.crash();
  }
}

class CrashTelemetry {
  factory CrashTelemetry({required CrashTelemetryBackend backend}) {
    return CrashTelemetry._(backend);
  }

  CrashTelemetry._(this._backend);

  factory CrashTelemetry.production() {
    return CrashTelemetry(backend: FirebaseCrashTelemetryBackend());
  }

  final CrashTelemetryBackend _backend;
  bool _enabled = false;

  bool get isEnabled => _enabled;

  Future<void> initialize([
    CrashTelemetryConfig config = const CrashTelemetryConfig(
      collectionEnabled: false,
      initializeFirebase: false,
      forceTestCrashOnStartup: false,
    ),
  ]) async {
    _enabled = false;
    if (!config.collectionEnabled) {
      return;
    }

    if (config.initializeFirebase) {
      await _backend.initializeFirebase();
    }
    await _backend.setCrashlyticsCollectionEnabled(true);
    _enabled = true;
  }

  void forceTestCrashIfRequested(CrashTelemetryConfig config) {
    if (!_enabled || !config.forceTestCrashOnStartup) {
      return;
    }

    _backend.crash();
  }

  void recordFlutterError(FlutterErrorDetails details) {
    if (!_enabled) {
      return;
    }

    unawaited(
      _backend.recordError(
        const SanitizedCrashTelemetryError.flutterFramework(),
        details.stack ?? StackTrace.empty,
        fatal: true,
        reason: CrashTelemetryReason.flutterFramework.value,
      ),
    );
  }

  bool recordPlatformError(Object error, StackTrace stack) {
    if (!_enabled) {
      return false;
    }

    unawaited(
      _backend.recordError(
        const SanitizedCrashTelemetryError.platformDispatcher(),
        stack,
        fatal: true,
        reason: CrashTelemetryReason.platformDispatcher.value,
      ),
    );
    return true;
  }

  void recordZoneError(Object error, StackTrace stack) {
    if (!_enabled) {
      return;
    }

    unawaited(
      _backend.recordError(
        const SanitizedCrashTelemetryError.dartZone(),
        stack,
        fatal: true,
        reason: CrashTelemetryReason.dartZone.value,
      ),
    );
  }
}

enum CrashTelemetryReason {
  flutterFramework('flutter_framework_error'),
  platformDispatcher('platform_dispatcher_error'),
  dartZone('dart_zone_error');

  const CrashTelemetryReason(this.value);

  final String value;
}

class SanitizedCrashTelemetryError implements Exception {
  const SanitizedCrashTelemetryError.flutterFramework()
    : _event = 'flutter_framework_error';

  const SanitizedCrashTelemetryError.platformDispatcher()
    : _event = 'platform_dispatcher_error';

  const SanitizedCrashTelemetryError.dartZone() : _event = 'dart_zone_error';

  final String _event;

  @override
  String toString() => 'CrashTelemetryEvent.$_event';
}
