// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Finnish (`fi`).
class AppLocalizationsFi extends AppLocalizations {
  AppLocalizationsFi([String locale = 'fi']) : super(locale);

  @override
  String get appTitle => 'MyArtCollection';

  @override
  String get collectionTab => 'Kokoelma';

  @override
  String get incompleteTab => 'Keskeneraiset';

  @override
  String get reportsTab => 'Raportit';

  @override
  String get settingsTab => 'Asetukset';

  @override
  String get addArtworkAction => 'Lisaa teos';

  @override
  String get takePhotoAction => 'Ota kuva';

  @override
  String get importPhotoAction => 'Tuo kuva';

  @override
  String get attachDocumentAction => 'Liita asiakirja';

  @override
  String get aiSuggestedLabel => 'AI-ehdotus';

  @override
  String get userConfirmedLabel => 'Sinun vahvistama';

  @override
  String get documentExtractedLabel => 'Poimittu asiakirjasta';

  @override
  String get unknownLabel => 'Tuntematon';

  @override
  String get comparableSourceSignalsTitle => 'Vertailtavat lahdesignaalit';

  @override
  String sourceLine(Object source) {
    return 'Lahde: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Viite: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Vertailusumma: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Signaalin paiva: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Kayttajan antama vakuutusarvo: $value.';
  }
}
