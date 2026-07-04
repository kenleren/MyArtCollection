import 'package:flutter/widgets.dart';

import 'intake/artwork_image_picker.dart';
import 'intake/artwork_intake_service.dart';
import 'storage/local_artwork_repository.dart';
import 'storage/local_attachment_store.dart';

class AppDependencies {
  const AppDependencies({
    required this.artworkRepository,
    required this.attachmentStore,
    required this.imagePicker,
  });

  final LocalArtworkRepository artworkRepository;
  final LocalAttachmentStore attachmentStore;
  final ArtworkImagePicker imagePicker;

  ArtworkIntakeService createIntakeService() {
    return ArtworkIntakeService(
      picker: imagePicker,
      repository: artworkRepository,
      attachmentStore: attachmentStore,
    );
  }
}

class AppDependencyScope extends InheritedWidget {
  const AppDependencyScope({
    super.key,
    required this.dependencies,
    required super.child,
  });

  final AppDependencies dependencies;

  static AppDependencies of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppDependencyScope>();
    assert(scope != null, 'AppDependencyScope was not found.');
    return scope!.dependencies;
  }

  @override
  bool updateShouldNotify(AppDependencyScope oldWidget) {
    return dependencies != oldWidget.dependencies;
  }
}
