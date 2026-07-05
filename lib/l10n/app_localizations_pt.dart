// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'Archivale';

  @override
  String get collectionTab => 'Colecao';

  @override
  String get incompleteTab => 'Incompleto';

  @override
  String get reportsTab => 'Relatorios';

  @override
  String get settingsTab => 'Definicoes';

  @override
  String get addArtworkAction => 'Adicionar obra';

  @override
  String get takePhotoAction => 'Tirar foto';

  @override
  String get importPhotoAction => 'Importar foto';

  @override
  String get attachDocumentAction => 'Anexar documento';

  @override
  String get aiSuggestedLabel => 'Sugestao de IA';

  @override
  String get userConfirmedLabel => 'Confirmado por si';

  @override
  String get documentExtractedLabel => 'Extraido do documento';

  @override
  String get unknownLabel => 'Desconhecido';

  @override
  String get comparableSourceSignalsTitle => 'Sinais comparaveis com fonte';

  @override
  String sourceLine(Object source) {
    return 'Fonte: $source';
  }

  @override
  String citationLine(Object url) {
    return 'Citacao: $url';
  }

  @override
  String comparableAmountLine(Object amount) {
    return 'Montante comparavel: $amount';
  }

  @override
  String signalDateLine(Object date) {
    return 'Data do sinal: $date';
  }

  @override
  String userProvidedInsuranceValueLine(Object value) {
    return 'Valor de seguro indicado por si: $value.';
  }
}
