import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'visual_evidence_output.dart';

void main() {
  test('visual evidence is ephemeral unless tracked updates are explicit', () {
    expect(
      p.normalize(visualEvidenceOutputDirectory(environment: const {}).path),
      p.normalize(p.join('.dart_tool', 'visual_evidence')),
    );
    expect(
      p.normalize(
        visualEvidenceOutputDirectory(
          environment: const {'UPDATE_VISUAL_ARTIFACTS': '0'},
        ).path,
      ),
      p.normalize(p.join('.dart_tool', 'visual_evidence')),
    );
    expect(
      p.normalize(
        visualEvidenceOutputDirectory(
          environment: const {'UPDATE_VISUAL_ARTIFACTS': '1'},
        ).path,
      ),
      p.normalize(p.join('artifacts', 'visual')),
    );
  });
}
