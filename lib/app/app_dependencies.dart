import 'package:flutter/widgets.dart';

import 'ai/on_device_ai_draft_service.dart';
import 'billing/entitlement_plan.dart';
import 'config/app_feature_flags.dart';
import 'import/csv_artwork_import_service.dart';
import 'import/csv_import_file_picker.dart';
import 'intake/artwork_image_picker.dart';
import 'intake/artwork_intake_service.dart';
import 'intake/supporting_attachment_service.dart';
import 'research/online_research_service.dart';
import 'storage/local_artwork_repository.dart';
import 'storage/local_attachment_store.dart';

class AppDependencies {
  const AppDependencies({
    required this.artworkRepository,
    required this.attachmentStore,
    required this.imagePicker,
    this.csvImportFilePicker = const SystemCsvImportFilePicker(),
    this.featureFlags = const AppFeatureFlags(),
    this.entitlementService = const StaticEntitlementService(),
    this.onDeviceAiDraftProvider = const DisabledOnDeviceAiDraftProvider(),
    this.onlineResearchClient,
  });

  final LocalArtworkRepository artworkRepository;
  final LocalAttachmentStore attachmentStore;
  final ArtworkImagePicker imagePicker;
  final CsvImportFilePicker csvImportFilePicker;
  final AppFeatureFlags featureFlags;
  final EntitlementService entitlementService;
  final OnDeviceAiDraftProvider onDeviceAiDraftProvider;
  final OnlineResearchClient? onlineResearchClient;

  ArtworkIntakeService createIntakeService() {
    return ArtworkIntakeService(
      picker: imagePicker,
      repository: artworkRepository,
      attachmentStore: attachmentStore,
    );
  }

  SupportingAttachmentService createSupportingAttachmentService() {
    return SupportingAttachmentService(
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

  OnlineResearchService createOnlineResearchService() {
    return OnlineResearchService(
      repository: artworkRepository,
      client: onlineResearchClient ?? FixtureProfessionalSourceResearchClient(),
    );
  }

  CsvArtworkImportService createCsvArtworkImportService() {
    return CsvArtworkImportService();
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
