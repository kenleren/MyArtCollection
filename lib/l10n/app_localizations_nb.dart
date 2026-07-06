// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Norwegian Bokmål (`nb`).
class AppLocalizationsNb extends AppLocalizations {
  AppLocalizationsNb([String locale = 'nb']) : super(locale);

  @override
  String get appTitle => 'Archivale';

  @override
  String get collectionTab => 'Samling';

  @override
  String get incompleteTab => 'Ufullstendig';

  @override
  String get reportsTab => 'Rapporter';

  @override
  String get settingsTab => 'Innstillinger';

  @override
  String get addArtworkAction => 'Legg til kunstverk';

  @override
  String get takePhotoAction => 'Ta bilde';

  @override
  String get importPhotoAction => 'Importer bilde';

  @override
  String get attachDocumentAction => 'Legg ved dokument';

  @override
  String get aiSuggestedLabel => 'AI-forslag';

  @override
  String get userConfirmedLabel => 'Bekreftet av deg';

  @override
  String get documentExtractedLabel => 'Hentet fra dokument';

  @override
  String get unknownLabel => 'Ukjent';

  @override
  String get comparableSourceSignalsTitle => 'Sammenlignbare kildesignaler';

  @override
  String sourceLine(Object source) {
    return 'Kilde: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Referanse: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Sammenlignbart beloep: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Signaldato: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Forsikringsverdi oppgitt av deg: $value.';
  }
}
