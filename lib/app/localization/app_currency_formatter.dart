import 'dart:ui';

import 'package:intl/intl.dart';

class AppCurrencyFormatter {
  const AppCurrencyFormatter._();

  static String comparableAmount({
    required Locale locale,
    required String? currencyCode,
    required String? amountLow,
    required String? amountHigh,
  }) {
    if (_isBlank(amountLow) && _isBlank(amountHigh)) {
      return '';
    }

    final code = currencyCode?.trim();
    final prefix = _isBlank(code) ? '' : '$code ';
    final low = _formatAmount(locale, amountLow);
    final high = _formatAmount(locale, amountHigh);

    if (!_isBlank(low) && !_isBlank(high)) {
      return '$prefix$low-$high';
    }
    return '$prefix${low.isEmpty ? high : low}';
  }

  static String _formatAmount(Locale locale, String? rawAmount) {
    if (_isBlank(rawAmount)) {
      return '';
    }

    final trimmed = rawAmount!.trim();
    final normalized = trimmed.replaceAll(RegExp(r'[\s,]'), '');
    final parsed = num.tryParse(normalized);
    if (parsed == null) {
      return trimmed;
    }

    final formatter = NumberFormat.decimalPattern(locale.toLanguageTag());
    return formatter.format(parsed);
  }

  static bool _isBlank(String? value) => value == null || value.trim().isEmpty;
}
