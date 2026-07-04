import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/config/app_feature_flags.dart';

void main() {
  test('online research feature flag defaults to disabled', () {
    const flags = AppFeatureFlags();

    expect(flags.onlineResearchEnabled, isFalse);
    expect(
      AppFeatureFlagKeys.allowlist,
      containsAll(<String>[AppFeatureFlagKeys.onlineResearchEnabled]),
    );
    expect(AppFeatureFlagKeys.allowlist, hasLength(1));
    expect(
      AppFeatureFlagDefaults.values[AppFeatureFlagKeys.onlineResearchEnabled],
      isFalse,
    );
  });

  test('online research feature flag can be injected enabled', () {
    const flags = AppFeatureFlags(onlineResearchEnabled: true);

    expect(flags.onlineResearchEnabled, isTrue);
  });

  test(
    'feature flag service falls back to defaults when backend fails',
    () async {
      final service = AppFeatureFlagService(
        backend: _ThrowingFeatureFlagBackend(),
        isReleaseMode: true,
        targetPlatform: TargetPlatform.android,
        firebaseAndroid: true,
        remoteConfigEnabled: true,
      );

      final flags = await service.load();

      expect(flags.onlineResearchEnabled, isFalse);
    },
  );

  test('feature flag service returns backend value when enabled', () async {
    final service = AppFeatureFlagService(
      backend: _EnabledFeatureFlagBackend(),
      isReleaseMode: true,
      targetPlatform: TargetPlatform.android,
      firebaseAndroid: true,
      remoteConfigEnabled: true,
    );

    final flags = await service.load();

    expect(flags.onlineResearchEnabled, isTrue);
  });

  test('feature flag service stays off in non-release builds', () async {
    final service = AppFeatureFlagService(
      backend: _EnabledFeatureFlagBackend(),
      isReleaseMode: false,
      targetPlatform: TargetPlatform.android,
      firebaseAndroid: true,
      remoteConfigEnabled: true,
    );

    final flags = await service.load();

    expect(flags.onlineResearchEnabled, isFalse);
  });

  test('feature flag service stays off outside Android', () async {
    final backend = _CountingEnabledFeatureFlagBackend();
    final service = AppFeatureFlagService(
      backend: backend,
      isReleaseMode: true,
      targetPlatform: TargetPlatform.iOS,
      firebaseAndroid: true,
      remoteConfigEnabled: true,
    );

    final flags = await service.load();

    expect(flags.onlineResearchEnabled, isFalse);
    expect(backend.calls, 0);
  });

  test(
    'feature flag service requires paired Firebase Android define',
    () async {
      final backend = _CountingEnabledFeatureFlagBackend();
      final service = AppFeatureFlagService(
        backend: backend,
        isReleaseMode: true,
        targetPlatform: TargetPlatform.android,
        firebaseAndroid: false,
        remoteConfigEnabled: true,
      );

      final flags = await service.load();

      expect(flags.onlineResearchEnabled, isFalse);
      expect(backend.calls, 0);
    },
  );

  test('feature flag service requires explicit Remote Config define', () async {
    final backend = _CountingEnabledFeatureFlagBackend();
    final service = AppFeatureFlagService(
      backend: backend,
      isReleaseMode: true,
      targetPlatform: TargetPlatform.android,
      firebaseAndroid: true,
      remoteConfigEnabled: false,
    );

    final flags = await service.load();

    expect(flags.onlineResearchEnabled, isFalse);
    expect(backend.calls, 0);
  });
}

class _ThrowingFeatureFlagBackend implements AppFeatureFlagBackend {
  @override
  Future<bool> onlineResearchEnabled() async {
    throw StateError('backend unavailable');
  }
}

class _EnabledFeatureFlagBackend implements AppFeatureFlagBackend {
  @override
  Future<bool> onlineResearchEnabled() async => true;
}

class _CountingEnabledFeatureFlagBackend implements AppFeatureFlagBackend {
  int calls = 0;

  @override
  Future<bool> onlineResearchEnabled() async {
    calls += 1;
    return true;
  }
}
