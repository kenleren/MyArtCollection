import 'package:flutter/widgets.dart';

import 'ai/on_device_ai_draft_service.dart';
import 'billing/entitlement_plan.dart';
import 'billing/play_billing_adapter.dart';
import 'config/app_feature_flags.dart';
import 'import/csv_artwork_import_service.dart';
import 'import/csv_import_file_picker.dart';
import 'intake/artwork_image_picker.dart';
import 'intake/attachment_viewer_gateway.dart';
import 'intake/artwork_intake_service.dart';
import 'intake/supporting_document_picker.dart';
import 'intake/supporting_attachment_service.dart';
import 'external_references/external_reference_launch_gateway.dart';
import 'external_references/external_reference_launch_service.dart';
import 'research/online_research_service.dart';
import 'storage/local_artwork_repository.dart';
import 'storage/local_attachment_store.dart';
import 'storage/ai_research_record.dart';

class AppDependencies {
  const AppDependencies({
    required this.artworkRepository,
    required this.attachmentStore,
    required this.imagePicker,
    this.supportingDocumentPicker = const SystemSupportingDocumentPicker(),
    this.attachmentViewer = const SystemAttachmentViewerGateway(),
    this.csvImportFilePicker = const SystemCsvImportFilePicker(),
    this.featureFlags = const AppFeatureFlags(),
    this.entitlementService = const StaticEntitlementService(),
    this.billingManagementService,
    this.onDeviceAiDraftProvider = const DisabledOnDeviceAiDraftProvider(),
    this.onlineResearchClient,
    this.externalReferenceLaunchGateway,
  });

  final LocalArtworkRepository artworkRepository;
  final LocalAttachmentStore attachmentStore;
  final ArtworkImagePicker imagePicker;
  final SupportingDocumentPicker supportingDocumentPicker;
  final AttachmentViewerGateway attachmentViewer;
  final CsvImportFilePicker csvImportFilePicker;
  final AppFeatureFlags featureFlags;
  final EntitlementService entitlementService;
  final BillingManagementService? billingManagementService;
  final OnDeviceAiDraftProvider onDeviceAiDraftProvider;
  final OnlineResearchClient? onlineResearchClient;
  final ExternalReferenceLaunchGateway? externalReferenceLaunchGateway;

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
      documentPicker: supportingDocumentPicker,
      viewer: attachmentViewer,
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
      client: onlineResearchClient ?? const _UnavailableOnlineResearchClient(),
    );
  }

  CsvArtworkImportService createCsvArtworkImportService() {
    return CsvArtworkImportService();
  }

  ExternalReferenceLaunchService createExternalReferenceLaunchService() {
    return ExternalReferenceLaunchService(
      repository: artworkRepository,
      gateway:
          externalReferenceLaunchGateway ??
          createSystemExternalReferenceLaunchGateway(),
    );
  }
}

class _UnavailableOnlineResearchClient implements OnlineResearchClient {
  const _UnavailableOnlineResearchClient();

  @override
  Future<ResearchJob> research(OnlineResearchRequest request) =>
      throw StateError('Online research is unavailable.');
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
