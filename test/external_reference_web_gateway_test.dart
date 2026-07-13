@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway_web.dart';

void main() {
  test('conditional gateway selects the synchronous web implementation', () {
    final gateway = createSystemExternalReferenceLaunchGateway();
    expect(gateway.target, ExternalReferenceLaunchTarget.web);
    expect(gateway.requiresSynchronousReservation, isTrue);
  });

  testWidgets('browser button reserves a tab with no opener', (tester) async {
    WebExternalReferenceLaunchReservation? reservation;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilledButton(
            onPressed: () => reservation = reserveIsolatedBlankTab(),
            child: const Text('Open reference'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open reference'));
    expect(reservation, isNotNull);
    expect(reservation!.hasNoOpener, isTrue);
    reservation!.close();
  });
}
