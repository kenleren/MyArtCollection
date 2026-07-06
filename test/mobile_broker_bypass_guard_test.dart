import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile source contains no direct provider bypass strings', () async {
    final result = await Process.run('node', [
      'scripts/mobile_broker_bypass_guard.mjs',
    ], workingDirectory: Directory.current.path);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
