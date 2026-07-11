import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'broker-capable Android startup removes Firebase providers and defers Dart initialization',
    () async {
      final manifest = await _read('android/app/src/main/AndroidManifest.xml');
      final gradle = await _read('android/app/build.gradle.kts');
      final main = await _read('lib/main.dart');

      expect(manifest, contains('FirebaseInitProvider'));
      expect(manifest, contains('CrashlyticsInitProvider'));
      expect(manifest, contains('tools:node="remove"'));
      expect(main, contains('featureFlagService.localFlags()'));
      expect(main, isNot(contains('loadAfterConsent()')));
      expect(
        gradle,
        contains('MY_ART_COLLECTION_BROKER_CLIENT=true cannot be combined'),
      );
      expect(gradle, contains('if (!brokerClientDartDefineEnabled)'));
      expect(
        gradle,
        contains('apply(plugin = "com.google.firebase.crashlytics")'),
      );
    },
  );
}

Future<String> _read(String relativePath) {
  return File(p.join(Directory.current.path, relativePath)).readAsString();
}
