// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Archivale';

  @override
  String get collectionTab => 'Collection';

  @override
  String get incompleteTab => 'Needs review';

  @override
  String get reportsTab => 'Reports';

  @override
  String get settingsTab => 'Settings';

  @override
  String get addArtworkAction => 'Add artwork';

  @override
  String get takePhotoAction => 'Take photo';

  @override
  String get importPhotoAction => 'Import photo';

  @override
  String get attachDocumentAction => 'Attach document';

  @override
  String get aiSuggestedLabel => 'AI-suggested';

  @override
  String get userConfirmedLabel => 'User confirmed';

  @override
  String get documentExtractedLabel => 'Document-extracted';

  @override
  String get unknownLabel => 'Unknown';

  @override
  String get comparableSourceSignalsTitle => 'Comparable source signals';

  @override
  String sourceLine(Object source) {
    return 'Source: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Citation: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Comparable amount: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Signal date: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'User-provided insurance value: $value.';
  }
}
