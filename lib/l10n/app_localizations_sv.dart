// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Swedish (`sv`).
class AppLocalizationsSv extends AppLocalizations {
  AppLocalizationsSv([String locale = 'sv']) : super(locale);

  @override
  String get appTitle => 'MyArtCollection';

  @override
  String get collectionTab => 'Samling';

  @override
  String get incompleteTab => 'Ofullstaendig';

  @override
  String get reportsTab => 'Rapporter';

  @override
  String get settingsTab => 'Instaellningar';

  @override
  String get addArtworkAction => 'Laegg till konstverk';

  @override
  String get takePhotoAction => 'Ta foto';

  @override
  String get importPhotoAction => 'Importera foto';

  @override
  String get attachDocumentAction => 'Bifoga dokument';

  @override
  String get aiSuggestedLabel => 'AI-foerslag';

  @override
  String get userConfirmedLabel => 'Bekraeftat av dig';

  @override
  String get documentExtractedLabel => 'Haemtat fraan dokument';

  @override
  String get unknownLabel => 'Okaent';

  @override
  String get comparableSourceSignalsTitle => 'Jaemfoerbara kaellsignaler';

  @override
  String sourceLine(Object source) {
    return 'Kaella: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Referens: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Jaemfoerbart belopp: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Signaldatum: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Foersaekringsvaerde angivet av dig: $value.';
  }
}
