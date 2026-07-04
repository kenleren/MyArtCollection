import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/localization/app_currency_formatter.dart';

void main() {
  test(
    'formats structured comparable amounts for locale without conversion',
    () {
      expect(
        AppCurrencyFormatter.comparableAmount(
          locale: const Locale('en'),
          currencyCode: 'USD',
          amountLow: '2200',
          amountHigh: '2800',
        ),
        'USD 2,200-2,800',
      );
      expect(
        AppCurrencyFormatter.comparableAmount(
          locale: const Locale('nb'),
          currencyCode: 'USD',
          amountLow: '2200',
          amountHigh: '2800',
        ),
        'USD 2 200-2 800',
      );
      expect(
        AppCurrencyFormatter.comparableAmount(
          locale: const Locale('fr'),
          currencyCode: 'EUR',
          amountLow: '2200',
          amountHigh: null,
        ),
        'EUR 2 200',
      );
    },
  );

  test('preserves nonnumeric amount text for source fidelity', () {
    expect(
      AppCurrencyFormatter.comparableAmount(
        locale: const Locale('de'),
        currencyCode: 'EUR',
        amountLow: 'about 2k',
        amountHigh: null,
      ),
      'EUR about 2k',
    );
  });
}
