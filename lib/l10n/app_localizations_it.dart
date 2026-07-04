// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Italian (`it`).
class AppLocalizationsIt extends AppLocalizations {
  AppLocalizationsIt([String locale = 'it']) : super(locale);

  @override
  String get appTitle => 'MyArtCollection';

  @override
  String get collectionTab => 'Collezione';

  @override
  String get incompleteTab => 'Incompleto';

  @override
  String get reportsTab => 'Report';

  @override
  String get settingsTab => 'Impostazioni';

  @override
  String get addArtworkAction => 'Aggiungi opera';

  @override
  String get takePhotoAction => 'Scatta foto';

  @override
  String get importPhotoAction => 'Importa foto';

  @override
  String get attachDocumentAction => 'Allega documento';

  @override
  String get aiSuggestedLabel => 'Suggerito da IA';

  @override
  String get userConfirmedLabel => 'Confermato da te';

  @override
  String get documentExtractedLabel => 'Estratto dal documento';

  @override
  String get unknownLabel => 'Sconosciuto';

  @override
  String get comparableSourceSignalsTitle => 'Segnali comparabili con fonte';

  @override
  String sourceLine(Object source) {
    return 'Fonte: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Citazione: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Importo comparabile: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Data del segnale: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Valore assicurativo fornito da te: $value.';
  }
}
