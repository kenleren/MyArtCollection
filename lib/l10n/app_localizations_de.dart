// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'Archivale';

  @override
  String get collectionTab => 'Sammlung';

  @override
  String get incompleteTab => 'Unvollstaendig';

  @override
  String get reportsTab => 'Berichte';

  @override
  String get settingsTab => 'Einstellungen';

  @override
  String get addArtworkAction => 'Kunstwerk hinzufuegen';

  @override
  String get takePhotoAction => 'Foto aufnehmen';

  @override
  String get importPhotoAction => 'Foto importieren';

  @override
  String get attachDocumentAction => 'Dokument anhaengen';

  @override
  String get aiSuggestedLabel => 'KI-Vorschlag';

  @override
  String get userConfirmedLabel => 'Von dir bestaetigt';

  @override
  String get documentExtractedLabel => 'Aus Dokument uebernommen';

  @override
  String get unknownLabel => 'Unbekannt';

  @override
  String get comparableSourceSignalsTitle => 'Vergleichbare Quellensignale';

  @override
  String sourceLine(Object source) {
    return 'Quelle: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Zitat: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Vergleichsbetrag: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Signaldatum: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Von dir angegebener Versicherungswert: $value.';
  }
}
