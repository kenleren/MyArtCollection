import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/telemetry/crash_telemetry.dart';
import 'package:path/path.dart' as p;

void main() {
  test('default environment keeps Crashlytics collection off', () {
    final config = CrashTelemetryConfig.fromEnvironment(
      isReleaseMode: false,
      targetPlatform: TargetPlatform.android,
      firebaseAndroid: true,
      internalBetaCrashlytics: true,
    );

    expect(config.collectionEnabled, isFalse);
    expect(config.initializeFirebase, isFalse);
    expect(config.forceTestCrashOnStartup, isFalse);
  });

  test('internal beta release enables Crashlytics explicitly', () {
    final config = CrashTelemetryConfig.fromEnvironment(
      isReleaseMode: true,
      targetPlatform: TargetPlatform.android,
      firebaseAndroid: true,
      internalBetaCrashlytics: true,
    );

    expect(config.collectionEnabled, isTrue);
    expect(config.initializeFirebase, isTrue);
    expect(config.forceTestCrashOnStartup, isFalse);
  });

  test('Crashlytics stays Android-only even with the beta define', () {
    final config = CrashTelemetryConfig.fromEnvironment(
      isReleaseMode: true,
      targetPlatform: TargetPlatform.iOS,
      firebaseAndroid: true,
      internalBetaCrashlytics: true,
    );

    expect(config.collectionEnabled, isFalse);
    expect(config.initializeFirebase, isFalse);
    expect(config.forceTestCrashOnStartup, isFalse);
  });

  test('Crashlytics requires paired Firebase Android Dart define', () {
    final config = CrashTelemetryConfig.fromEnvironment(
      isReleaseMode: true,
      targetPlatform: TargetPlatform.android,
      firebaseAndroid: false,
      internalBetaCrashlytics: true,
    );

    expect(config.collectionEnabled, isFalse);
    expect(config.initializeFirebase, isFalse);
    expect(config.forceTestCrashOnStartup, isFalse);
  });

  test(
    'test crash requires release, internal beta, and test-crash defines',
    () {
      final config = CrashTelemetryConfig.fromEnvironment(
        isReleaseMode: true,
        targetPlatform: TargetPlatform.android,
        firebaseAndroid: true,
        internalBetaCrashlytics: true,
        crashlyticsTestCrash: true,
      );

      expect(config.forceTestCrashOnStartup, isTrue);
      expect(
        CrashTelemetryConfig.fromEnvironment(
          isReleaseMode: false,
          targetPlatform: TargetPlatform.android,
          firebaseAndroid: true,
          internalBetaCrashlytics: true,
          crashlyticsTestCrash: true,
        ).forceTestCrashOnStartup,
        isFalse,
      );
    },
  );

  test(
    'disabled telemetry does not initialize Firebase or record errors',
    () async {
      final backend = _FakeCrashTelemetryBackend();
      final telemetry = CrashTelemetry(backend: backend);

      await telemetry.initialize(
        const CrashTelemetryConfig(
          collectionEnabled: false,
          initializeFirebase: false,
          forceTestCrashOnStartup: false,
        ),
      );

      telemetry.recordFlutterError(
        FlutterErrorDetails(
          exception: StateError('Private title /Users/tester/artwork.jpg'),
          stack: StackTrace.current,
        ),
      );
      final handled = telemetry.recordPlatformError(
        StateError('private prompt token firebase-token'),
        StackTrace.current,
      );
      telemetry.recordZoneError(
        StateError('research query https://example.test/source'),
        StackTrace.current,
      );

      expect(telemetry.isEnabled, isFalse);
      expect(handled, isFalse);
      expect(backend.initializeFirebaseCalls, 0);
      expect(backend.collectionStates, isEmpty);
      expect(backend.recordedErrors, isEmpty);
      expect(backend.crashCalls, 0);
    },
  );

  test('enabled telemetry records only sanitized fixed reasons', () async {
    final backend = _FakeCrashTelemetryBackend();
    final telemetry = CrashTelemetry(backend: backend);

    await telemetry.initialize(
      const CrashTelemetryConfig(
        collectionEnabled: true,
        initializeFirebase: true,
        forceTestCrashOnStartup: false,
      ),
    );
    telemetry.recordFlutterError(
      FlutterErrorDetails(
        exception: StateError('Blue Interior Study /tmp/receipt.pdf api-key'),
        stack: StackTrace.current,
        informationCollector: () sync* {
          yield ErrorDescription('artist name and research query');
        },
      ),
    );
    final handled = telemetry.recordPlatformError(
      StateError('private location and source citation'),
      StackTrace.current,
    );
    telemetry.recordZoneError(
      StateError('seller buyer gallery auction house'),
      StackTrace.current,
    );

    await Future<void>.delayed(Duration.zero);

    expect(telemetry.isEnabled, isTrue);
    expect(handled, isTrue);
    expect(backend.initializeFirebaseCalls, 1);
    expect(backend.collectionStates, [true]);
    expect(backend.recordedErrors.map((record) => record.reason), [
      'flutter_framework_error',
      'platform_dispatcher_error',
      'dart_zone_error',
    ]);
    for (final record in backend.recordedErrors) {
      final serialized = '${record.error} ${record.reason}';
      expect(serialized, isNot(contains('Blue Interior Study')));
      expect(serialized, isNot(contains('/tmp/receipt.pdf')));
      expect(serialized, isNot(contains('api-key')));
      expect(serialized, isNot(contains('artist name')));
      expect(serialized, isNot(contains('research query')));
      expect(serialized, isNot(contains('source citation')));
      expect(serialized, isNot(contains('seller')));
      expect(serialized, isNot(contains('gallery')));
    }
  });

  test('test crash path stays behind enabled telemetry config', () async {
    final backend = _FakeCrashTelemetryBackend();
    final telemetry = CrashTelemetry(backend: backend);

    telemetry.forceTestCrashIfRequested(
      const CrashTelemetryConfig(
        collectionEnabled: true,
        initializeFirebase: true,
        forceTestCrashOnStartup: true,
      ),
    );
    expect(backend.crashCalls, 0);

    await telemetry.initialize(
      const CrashTelemetryConfig(
        collectionEnabled: true,
        initializeFirebase: true,
        forceTestCrashOnStartup: false,
      ),
    );
    telemetry.forceTestCrashIfRequested(
      const CrashTelemetryConfig(
        collectionEnabled: true,
        initializeFirebase: true,
        forceTestCrashOnStartup: true,
      ),
    );

    expect(backend.crashCalls, 1);
  });

  test('Crashlytics SDK usage stays inside the telemetry facade', () async {
    final repoRoot = Directory.current;
    final dartFiles = await repoRoot
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.dart'))
        .cast<File>()
        .where((file) {
          final relativePath = p.relative(file.path, from: repoRoot.path);
          return relativePath.startsWith('lib${p.separator}') ||
              relativePath.startsWith('test${p.separator}');
        })
        .toList();

    final violations = <String>[];
    for (final file in dartFiles) {
      final relativePath = p.relative(file.path, from: repoRoot.path);
      if (relativePath ==
              p.join('lib', 'app', 'telemetry', 'crash_telemetry.dart') ||
          relativePath == p.join('test', 'crash_telemetry_test.dart')) {
        continue;
      }
      final source = await file.readAsString();
      if (source.contains('firebase_crashlytics') ||
          source.contains('FirebaseCrashlytics')) {
        violations.add(relativePath);
      }
    }

    expect(violations, isEmpty);
  });

  test('telemetry facade does not add custom keys or logs', () async {
    final source = await File(
      p.join('lib', 'app', 'telemetry', 'crash_telemetry.dart'),
    ).readAsString();

    expect(source, isNot(contains('setCustomKey')));
    expect(source, isNot(contains('.log(')));
  });
}

class _FakeCrashTelemetryBackend implements CrashTelemetryBackend {
  int initializeFirebaseCalls = 0;
  int crashCalls = 0;
  final collectionStates = <bool>[];
  final recordedErrors = <_RecordedCrash>[];

  @override
  void crash() {
    crashCalls += 1;
  }

  @override
  Future<void> initializeFirebase() async {
    initializeFirebaseCalls += 1;
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace stack, {
    required bool fatal,
    required String reason,
  }) async {
    recordedErrors.add(
      _RecordedCrash(error: error, fatal: fatal, reason: reason),
    );
  }

  @override
  Future<void> setCrashlyticsCollectionEnabled(bool enabled) async {
    collectionStates.add(enabled);
  }
}

class _RecordedCrash {
  const _RecordedCrash({
    required this.error,
    required this.fatal,
    required this.reason,
  });

  final Object error;
  final bool fatal;
  final String reason;
}
