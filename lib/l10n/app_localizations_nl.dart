// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Dutch Flemish (`nl`).
class AppLocalizationsNl extends AppLocalizations {
  AppLocalizationsNl([String locale = 'nl']) : super(locale);

  @override
  String get appTitle => 'Archivale';

  @override
  String get collectionTab => 'Collectie';

  @override
  String get incompleteTab => 'Onvolledig';

  @override
  String get reportsTab => 'Rapporten';

  @override
  String get settingsTab => 'Instellingen';

  @override
  String get addArtworkAction => 'Kunstwerk toevoegen';

  @override
  String get takePhotoAction => 'Foto maken';

  @override
  String get importPhotoAction => 'Foto importeren';

  @override
  String get attachDocumentAction => 'Document toevoegen';

  @override
  String get aiSuggestedLabel => 'AI-suggestie';

  @override
  String get userConfirmedLabel => 'Door jou bevestigd';

  @override
  String get documentExtractedLabel => 'Uit document gehaald';

  @override
  String get unknownLabel => 'Onbekend';

  @override
  String get comparableSourceSignalsTitle => 'Vergelijkbare bronsignalen';

  @override
  String sourceLine(Object source) {
    return 'Bron: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Citaat: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Vergelijkbaar bedrag: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Signaaldatum: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Door jou opgegeven verzekeringswaarde: $value.';
  }
}
