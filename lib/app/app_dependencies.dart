import 'package:flutter/widgets.dart';

import 'ai/on_device_ai_draft_service.dart';
import 'intake/artwork_image_picker.dart';
import 'intake/artwork_intake_service.dart';
import 'storage/local_artwork_repository.dart';
import 'storage/local_attachment_store.dart';

class AppDependencies {
  const AppDependencies({
    required this.artworkRepository,
    required this.attachmentStore,
    required this.imagePicker,
    this.onDeviceAiDraftProvider = const DisabledOnDeviceAiDraftProvider(),
  });

  final LocalArtworkRepository artworkRepository;
  final LocalAttachmentStore attachmentStore;
  final ArtworkImagePicker imagePicker;
  final OnDeviceAiDraftProvider onDeviceAiDraftProvider;

  ArtworkIntakeService createIntakeService() {
    return ArtworkIntakeService(
      picker: imagePicker,
      repository: artworkRepository,
      attachmentStore: attachmentStore,
    );
  }

  OnDeviceAiDraftService createOnDeviceAiDraftService() {
    return OnDeviceAiDraftService(
      repository: artworkRepository,
      attachmentStore: attachmentStore,
      provider: onDeviceAiDraftProvider,
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
