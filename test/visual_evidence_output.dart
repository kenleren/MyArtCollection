import 'dart:io';

import 'package:path/path.dart' as p;

const _updateTrackedVisualArtifacts = 'UPDATE_VISUAL_ARTIFACTS';

/// Keeps ordinary test runs byte-clean while retaining an explicit reference
/// regeneration path: `UPDATE_VISUAL_ARTIFACTS=1 flutter test`.
Directory visualEvidenceOutputDirectory({Map<String, String>? environment}) {
  final shouldUpdateTrackedArtifacts =
      (environment ?? Platform.environment)[_updateTrackedVisualArtifacts] ==
      '1';
  return Directory(
    p.join(
      shouldUpdateTrackedArtifacts ? 'artifacts' : '.dart_tool',
      shouldUpdateTrackedArtifacts ? 'visual' : 'visual_evidence',
    ),
  );
}
