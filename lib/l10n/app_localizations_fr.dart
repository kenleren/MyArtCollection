// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'Archivale';

  @override
  String get collectionTab => 'Collection';

  @override
  String get incompleteTab => 'Incomplet';

  @override
  String get reportsTab => 'Rapports';

  @override
  String get settingsTab => 'Reglages';

  @override
  String get addArtworkAction => 'Ajouter une oeuvre';

  @override
  String get takePhotoAction => 'Prendre une photo';

  @override
  String get importPhotoAction => 'Importer une photo';

  @override
  String get attachDocumentAction => 'Joindre un document';

  @override
  String get aiSuggestedLabel => 'Suggestion IA';

  @override
  String get userConfirmedLabel => 'Confirme par vous';

  @override
  String get documentExtractedLabel => 'Extrait du document';

  @override
  String get unknownLabel => 'Inconnu';

  @override
  String get comparableSourceSignalsTitle => 'Signaux comparables sources';

  @override
  String sourceLine(Object source) {
    return 'Source : $source';
  }

  @override
  String citationLine(Object url) {
    return 'Citation : $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Montant comparable : $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Date du signal : $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Valeur assurance fournie par vous : $value.';
  }
}
