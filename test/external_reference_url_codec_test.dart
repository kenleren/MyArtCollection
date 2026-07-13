import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/external_references/external_reference_url_codec.dart';

void main() {
  const codec = ExternalReferenceUrlCodec();

  group('ExternalReferenceUrlCodec accepts and canonicalizes', () {
    final cases = <String, String>{
      ' HTTPS://Example.COM:0443 ': 'https://example.com',
      'https://example.com': 'https://example.com',
      'https://example.com/': 'https://example.com/',
      'https://example.com:00444/path?b=2&a=1#part':
          'https://example.com:444/path?b=2&a=1#part',
      'https://xn--bcher-kva.example/%E2%82%AC?q=%2F#kept':
          'https://xn--bcher-kva.example/%E2%82%AC?q=%2F#kept',
      'https://192.0.2.1/object': 'https://192.0.2.1/object',
      'https://[2001:0DB8:0:0:0:0:0:1]/object': 'https://[2001:db8::1]/object',
      'https://[2001:0:0:1:0:0:1:1]': 'https://[2001::1:0:0:1:1]',
      'https://[::ffff:192.0.2.1]': 'https://[::ffff:c000:201]',
      'https://example.com/%E2%82%AC': 'https://example.com/%E2%82%AC',
    };

    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(codec.canonicalize(entry.key), entry.value);
      });
    }

    test('equality collapses authority variants only', () {
      expect(
        codec.equals('HTTPS://EXAMPLE.COM:443', 'https://example.com'),
        isTrue,
      );
      expect(
        codec.equals('https://example.com', 'https://example.com/'),
        isFalse,
      );
      expect(
        codec.equals('https://example.com/%2F', 'https://example.com//'),
        isFalse,
      );
      expect(
        codec.equals(
          'https://example.com?a=1&b=2',
          'https://example.com?b=2&a=1',
        ),
        isFalse,
      );
      expect(
        codec.equals('https://example.com#one', 'https://example.com#two'),
        isFalse,
      );
    });
  });

  group('ExternalReferenceUrlCodec rejects', () {
    final cases = <String, ExternalReferenceUrlFailure>{
      '': ExternalReferenceUrlFailure.invalidCharacters,
      '   ': ExternalReferenceUrlFailure.invalidCharacters,
      '\thttps://example.com': ExternalReferenceUrlFailure.invalidCharacters,
      'https://example.com/a b': ExternalReferenceUrlFailure.invalidCharacters,
      'https://example.com\\path':
          ExternalReferenceUrlFailure.invalidCharacters,
      'https://bücher.example': ExternalReferenceUrlFailure.invalidCharacters,
      'https://example.com/%':
          ExternalReferenceUrlFailure.invalidPercentEncoding,
      'https://example.com/%0G':
          ExternalReferenceUrlFailure.invalidPercentEncoding,
      'https://example.com/%C3%28':
          ExternalReferenceUrlFailure.invalidPercentEncoding,
      'https://example.com/%00':
          ExternalReferenceUrlFailure.invalidPercentEncoding,
      'https://example.com/%C2%80':
          ExternalReferenceUrlFailure.invalidPercentEncoding,
      'https://example.com/%5C':
          ExternalReferenceUrlFailure.invalidPercentEncoding,
      'http://example.com': ExternalReferenceUrlFailure.invalidScheme,
      'https:/example.com': ExternalReferenceUrlFailure.invalidScheme,
      'https://': ExternalReferenceUrlFailure.invalidAuthority,
      'https://@example.com': ExternalReferenceUrlFailure.invalidAuthority,
      'https://user@example.com': ExternalReferenceUrlFailure.invalidAuthority,
      'https://example.com@': ExternalReferenceUrlFailure.invalidAuthority,
      'https://example%2Ecom': ExternalReferenceUrlFailure.invalidHost,
      'https://example.com.': ExternalReferenceUrlFailure.invalidHost,
      'https://example..com': ExternalReferenceUrlFailure.invalidHost,
      'https://under_score.example': ExternalReferenceUrlFailure.invalidHost,
      'https://-start.example': ExternalReferenceUrlFailure.invalidHost,
      'https://end-.example': ExternalReferenceUrlFailure.invalidHost,
      'https://127.1': ExternalReferenceUrlFailure.invalidHost,
      'https://127.00.0.1': ExternalReferenceUrlFailure.invalidHost,
      'https://256.0.0.1': ExternalReferenceUrlFailure.invalidHost,
      'https://2130706433': ExternalReferenceUrlFailure.invalidHost,
      'https://0x7f000001': ExternalReferenceUrlFailure.invalidHost,
      'https://0x7f.0.0.1': ExternalReferenceUrlFailure.invalidHost,
      'https://2001:db8::1': ExternalReferenceUrlFailure.invalidHost,
      'https://[2001::1%25en0]': ExternalReferenceUrlFailure.invalidHost,
      'https://[1::2::3]': ExternalReferenceUrlFailure.invalidHost,
      'https://example.com:': ExternalReferenceUrlFailure.invalidPort,
      'https://example.com:+443': ExternalReferenceUrlFailure.invalidPort,
      'https://example.com:0': ExternalReferenceUrlFailure.invalidPort,
      'https://example.com:65536': ExternalReferenceUrlFailure.invalidPort,
      'https://example.com/.': ExternalReferenceUrlFailure.unsafePath,
      'https://example.com/..': ExternalReferenceUrlFailure.unsafePath,
      'https://example.com/%2e': ExternalReferenceUrlFailure.unsafePath,
      'https://example.com/.%2E/child': ExternalReferenceUrlFailure.unsafePath,
      'https://example.com/a/../b': ExternalReferenceUrlFailure.unsafePath,
      'https://example.com/a|b': ExternalReferenceUrlFailure.nonCanonicalUri,
    };

    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(
          () => codec.canonicalize(entry.key),
          throwsA(
            isA<ExternalReferenceUrlException>().having(
              (error) => error.failure,
              'failure',
              entry.value,
            ),
          ),
        );
      });
    }

    test('host length and canonical UTF-8 byte limit', () {
      final longLabel = List.filled(63, 'a').join();
      expect(
        () => codec.canonicalize(
          'https://$longLabel.$longLabel.$longLabel.$longLabel',
        ),
        throwsA(isA<ExternalReferenceUrlException>()),
      );
      expect(
        () => codec.canonicalize(
          'https://example.com/${List.filled(2030, 'a').join()}',
        ),
        throwsA(
          isA<ExternalReferenceUrlException>().having(
            (error) => error.failure,
            'failure',
            ExternalReferenceUrlFailure.tooLong,
          ),
        ),
      );
    });
  });
}
