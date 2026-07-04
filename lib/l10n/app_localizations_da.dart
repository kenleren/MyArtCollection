// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Danish (`da`).
class AppLocalizationsDa extends AppLocalizations {
  AppLocalizationsDa([String locale = 'da']) : super(locale);

  @override
  String get appTitle => 'MyArtCollection';

  @override
  String get collectionTab => 'Samling';

  @override
  String get incompleteTab => 'Ufuldstaendig';

  @override
  String get reportsTab => 'Rapporter';

  @override
  String get settingsTab => 'Indstillinger';

  @override
  String get addArtworkAction => 'Tilfoej kunstvaerk';

  @override
  String get takePhotoAction => 'Tag foto';

  @override
  String get importPhotoAction => 'Importer foto';

  @override
  String get attachDocumentAction => 'Vedhaeft dokument';

  @override
  String get aiSuggestedLabel => 'AI-forslag';

  @override
  String get userConfirmedLabel => 'Bekraeftet af dig';

  @override
  String get documentExtractedLabel => 'Hentet fra dokument';

  @override
  String get unknownLabel => 'Ukendt';

  @override
  String get comparableSourceSignalsTitle => 'Sammenlignelige kildesignaler';

  @override
  String sourceLine(Object source) {
    return 'Kilde: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Reference: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Sammenligneligt beloeb: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Signaldato: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Forsikringsvaerdi angivet af dig: $value.';
  }
}
