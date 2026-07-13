@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway.dart';

void main() {
  test('conditional gateway selects the synchronous web implementation', () {
    expect(
      createSystemExternalReferenceLaunchGateway().target,
      ExternalReferenceLaunchTarget.web,
    );
  });
}
