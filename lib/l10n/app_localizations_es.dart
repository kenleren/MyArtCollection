// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Archivale';

  @override
  String get collectionTab => 'Coleccion';

  @override
  String get incompleteTab => 'Incompleto';

  @override
  String get reportsTab => 'Informes';

  @override
  String get settingsTab => 'Ajustes';

  @override
  String get addArtworkAction => 'Anadir obra';

  @override
  String get takePhotoAction => 'Tomar foto';

  @override
  String get importPhotoAction => 'Importar foto';

  @override
  String get attachDocumentAction => 'Adjuntar documento';

  @override
  String get aiSuggestedLabel => 'Sugerido por IA';

  @override
  String get userConfirmedLabel => 'Confirmado por ti';

  @override
  String get documentExtractedLabel => 'Extraido del documento';

  @override
  String get unknownLabel => 'Desconocido';

  @override
  String get comparableSourceSignalsTitle => 'Senales comparables con fuente';

  @override
  String sourceLine(Object source) {
    return 'Fuente: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Cita: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Importe comparable: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Fecha de senal: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Valor de seguro indicado por ti: $value.';
  }
}
