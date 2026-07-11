import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/app_dependencies.dart';
import 'app/ai/on_device_ai_draft_service.dart';
import 'app/billing/play_billing_adapter.dart';
import 'app/config/app_feature_flags.dart';
import 'app/intake/artwork_image_picker.dart';
import 'app/research/firebase_research_runtime.dart';
import 'app/research/broker_http_client.dart';
import 'app/research/broker_online_research_client.dart';
import 'app/startup_route.dart';
import 'app/storage/local_artwork_repository.dart';
import 'app/storage/local_attachment_store.dart';
import 'app/telemetry/crash_telemetry.dart';

Future<void> main() async {
  final crashTelemetry = CrashTelemetry.production();

  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    final telemetryConfig = CrashTelemetryConfig.fromEnvironment();
    await crashTelemetry.initialize(telemetryConfig);
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      crashTelemetry.recordFlutterError(details);
    };
    PlatformDispatcher.instance.onError = crashTelemetry.recordPlatformError;
    crashTelemetry.forceTestCrashIfRequested(telemetryConfig);

    SystemArtworkImagePicker.configurePlatformPicker();

    final artworkRepository = await LocalArtworkRepository.open();
    final attachmentStore = await LocalAttachmentStore.open();
    // Firebase-backed feature evaluation is intentionally not part of startup.
    // Consent-gated research initializes it only after confirmed consent.
    final researchRuntime = FlutterFirebaseResearchRuntime();
    final featureFlagService = AppFeatureFlagService(runtime: researchRuntime);
    final featureFlags = featureFlagService.localFlags();
    final brokerEndpoint = featureFlagService.configuredBrokerEndpoint;
    final researchClient =
        featureFlags.localResearchCapabilityEnabled && brokerEndpoint != null
        ? BrokerOnlineResearchClient(
            imageSource: LocalBrokerResearchImageSource(
              repository: artworkRepository,
              attachmentStore: attachmentStore,
            ),
            httpClient: BrokerHttpClient(
              endpoint: brokerEndpoint,
              featureFlags: featureFlagService,
              firebaseRuntime: researchRuntime,
              transport: DartIoBrokerHttpTransport(),
              connectivity: const EndpointDnsBrokerConnectivity(),
              retryStore: await FileBrokerRetryStore.open(),
            ),
          )
        : null;
    final billingService = PlayBillingEntitlementService(
      InAppPurchasePlayBillingStore(),
      FirebasePlayBillingVerifier(FlutterFirebaseResearchRuntime()),
    );
    final dependencies = AppDependencies(
      artworkRepository: artworkRepository,
      attachmentStore: attachmentStore,
      imagePicker: SystemArtworkImagePicker(),
      featureFlags: featureFlags,
      entitlementService: billingService,
      billingManagementService: billingService,
      onDeviceAiDraftProvider: MethodChannelOnDeviceAiDraftProvider(),
      onlineResearchClient: researchClient,
    );

    runApp(
      ArchivaleApp(
        dependencies: dependencies,
        initialRoute: await initialRouteForRepository(artworkRepository),
      ),
    );
  }, crashTelemetry.recordZoneError);
}
