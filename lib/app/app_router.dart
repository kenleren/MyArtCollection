import 'package:flutter/material.dart';

import 'app_routes.dart';
import 'prototype/prototype_artwork.dart';
import 'screens/app_shell.dart';
import 'screens/prototype_flow.dart';

class AppRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final name = settings.name ?? AppRoutes.splash;

    switch (name) {
      case AppRoutes.splash:
        return _page(settings: settings, child: const PrototypeIntroScreen());
      case AppRoutes.onboarding:
        return _page(
          settings: settings,
          child: const PrototypeOnboardingScreen(),
        );
      case AppRoutes.onboardingPrivacy:
        return _page(settings: settings, child: const PrototypePrivacyScreen());
      case AppRoutes.onboardingFirstAdd:
        return _page(settings: settings, child: const AddArtworkScreen());
      case AppRoutes.collection:
      case AppRoutes.collectionIncomplete:
      case AppRoutes.collectionReport:
      case AppRoutes.collectionSettings:
      case AppRoutes.settings:
        return _page(
          settings: settings,
          child: AppShell(currentRoute: name),
        );
      case AppRoutes.collectionAdd:
        return _page(settings: settings, child: const AddArtworkScreen());
      case AppRoutes.capture:
        return _page(
          settings: settings,
          child: const CaptureImportScreen(mode: 'capture'),
        );
      case AppRoutes.import:
        return _page(
          settings: settings,
          child: const CaptureImportScreen(mode: 'import'),
        );
      case AppRoutes.settingsPrivacy:
        return _page(settings: settings, child: const PrototypePrivacyScreen());
      case AppRoutes.settingsStorage:
        return _page(settings: settings, child: const SettingsHomeScreen());
      case AppRoutes.settingsExport:
        return _page(
          settings: settings,
          child: const ExportPreviewScreen(artwork: prototypeArtwork),
        );
      case AppRoutes.settingsBackup:
        return _page(settings: settings, child: const SettingsHomeScreen());
      default:
        final artworkScreen = _artworkRoute(name, settings);
        if (artworkScreen != null) {
          return artworkScreen;
        }
        return _page(
          settings: settings,
          child: const PrototypeScreenFrame(
            title: 'Route not found',
            subtitle: 'Could not determine destination',
            child: Text('Please confirm the route before continuing.'),
          ),
        );
    }
  }

  static Route<dynamic>? _artworkRoute(String name, RouteSettings settings) {
    final segments = Uri.parse(name).pathSegments;
    if (segments.length < 2 || segments.first != 'artwork') {
      return null;
    }

    final suffix = segments.length > 2 ? segments.sublist(2).join('/') : '';
    final artwork = prototypeArtwork;

    return switch (suffix) {
      '' => _page(
        settings: settings,
        child: ArtworkDetailsScreen(artwork: artwork),
      ),
      'draft' => _page(
        settings: settings,
        child: DraftReviewScreen(artwork: artwork),
      ),
      'details' => _page(
        settings: settings,
        child: ArtworkDetailsScreen(artwork: artwork),
      ),
      'documents' => _page(
        settings: settings,
        child: DocumentsScreen(artwork: artwork),
      ),
      'report-preview' => _page(
        settings: settings,
        child: ReportPreviewScreen(artwork: artwork),
      ),
      'export' => _page(
        settings: settings,
        child: ExportPreviewScreen(artwork: artwork),
      ),
      _ => null,
    };
  }

  static MaterialPageRoute<dynamic> _page({
    required RouteSettings settings,
    required Widget child,
  }) {
    return MaterialPageRoute<void>(settings: settings, builder: (_) => child);
  }
}
