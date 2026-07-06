// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Polish (`pl`).
class AppLocalizationsPl extends AppLocalizations {
  AppLocalizationsPl([String locale = 'pl']) : super(locale);

  @override
  String get appTitle => 'Archivale';

  @override
  String get collectionTab => 'Kolekcja';

  @override
  String get incompleteTab => 'Niekompletne';

  @override
  String get reportsTab => 'Raporty';

  @override
  String get settingsTab => 'Ustawienia';

  @override
  String get addArtworkAction => 'Dodaj dzielo';

  @override
  String get takePhotoAction => 'Zrob zdjecie';

  @override
  String get importPhotoAction => 'Importuj zdjecie';

  @override
  String get attachDocumentAction => 'Dolacz dokument';

  @override
  String get aiSuggestedLabel => 'Sugestia AI';

  @override
  String get userConfirmedLabel => 'Potwierdzone przez ciebie';

  @override
  String get documentExtractedLabel => 'Pobrane z dokumentu';

  @override
  String get unknownLabel => 'Nieznane';

  @override
  String get comparableSourceSignalsTitle => 'Porownywalne sygnaly zrodlowe';

  @override
  String sourceLine(Object source) {
    return 'Zrodlo: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Cytat: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Porownywalna kwota: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Data sygnalu: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Wartosc ubezpieczenia podana przez ciebie: $value.';
  }
}
