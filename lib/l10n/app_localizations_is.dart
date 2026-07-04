// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Icelandic (`is`).
class AppLocalizationsIs extends AppLocalizations {
  AppLocalizationsIs([String locale = 'is']) : super(locale);

  @override
  String get appTitle => 'MyArtCollection';

  @override
  String get collectionTab => 'Safn';

  @override
  String get incompleteTab => 'Oklara';

  @override
  String get reportsTab => 'Skyrslur';

  @override
  String get settingsTab => 'Stillingar';

  @override
  String get addArtworkAction => 'Baeta vid verki';

  @override
  String get takePhotoAction => 'Taka mynd';

  @override
  String get importPhotoAction => 'Flytja inn mynd';

  @override
  String get attachDocumentAction => 'Hengja vid skjal';

  @override
  String get aiSuggestedLabel => 'AI-tillaga';

  @override
  String get userConfirmedLabel => 'Stadfest af ther';

  @override
  String get documentExtractedLabel => 'Sott ur skjali';

  @override
  String get unknownLabel => 'Othekkt';

  @override
  String get comparableSourceSignalsTitle => 'Samanburdarmerki ur heimildum';

  @override
  String sourceLine(Object source) {
    return 'Heimild: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Tilvisun: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Samanburdarupphaed: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Dagsetning merkis: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Tryggingarverd gefid upp af ther: $value.';
  }
}
