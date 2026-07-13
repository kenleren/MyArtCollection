import 'dart:convert';

enum ExternalReferenceUrlFailure {
  invalidCharacters,
  invalidPercentEncoding,
  invalidScheme,
  invalidAuthority,
  invalidHost,
  invalidPort,
  unsafePath,
  nonCanonicalUri,
  tooLong,
}

class ExternalReferenceUrlException implements Exception {
  const ExternalReferenceUrlException(this.failure, this.message);
  final ExternalReferenceUrlFailure failure;
  final String message;

  @override
  String toString() => message;
}

class ExternalReferenceUrlCodec {
  const ExternalReferenceUrlCodec();

  String canonicalize(String raw) {
    _rejectRawCharacters(raw);
    final value = _trimAsciiSpace(raw);
    if (value.isEmpty || value.contains(' ')) throw _invalidCharacters;
    _validatePercentRuns(value);
    if (value.length < 8 || value.substring(0, 8).toLowerCase() != 'https://') {
      throw const ExternalReferenceUrlException(
        ExternalReferenceUrlFailure.invalidScheme,
        'Use a complete https:// address.',
      );
    }

    final remainder = value.substring(8);
    final authorityEnd = _firstDelimiter(remainder);
    final authority = remainder.substring(0, authorityEnd);
    final suffix = remainder.substring(authorityEnd);
    if (authority.isEmpty || authority.contains('@')) {
      throw const ExternalReferenceUrlException(
        ExternalReferenceUrlFailure.invalidAuthority,
        'The address must have a host and cannot contain user information.',
      );
    }
    final parsedAuthority = _canonicalAuthority(authority);
    _validatePath(suffix);
    final candidate =
        'https://${parsedAuthority.host}'
        '${parsedAuthority.port == null ? '' : ':${parsedAuthority.port}'}$suffix';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.toString() != candidate) {
      throw const ExternalReferenceUrlException(
        ExternalReferenceUrlFailure.nonCanonicalUri,
        'The address cannot be represented without changing it.',
      );
    }
    if (utf8.encode(candidate).length > 2048) {
      throw const ExternalReferenceUrlException(
        ExternalReferenceUrlFailure.tooLong,
        'The address must be at most 2048 bytes.',
      );
    }
    return candidate;
  }

  bool equals(String left, String right) =>
      canonicalize(left) == canonicalize(right);

  void _rejectRawCharacters(String value) {
    for (final unit in value.codeUnits) {
      if (unit > 0x7f || unit <= 0x1f || unit == 0x7f || unit == 0x5c) {
        throw _invalidCharacters;
      }
    }
  }

  String _trimAsciiSpace(String value) {
    var start = 0;
    var end = value.length;
    while (start < end && value.codeUnitAt(start) == 0x20) {
      start++;
    }
    while (end > start && value.codeUnitAt(end - 1) == 0x20) {
      end--;
    }
    return value.substring(start, end);
  }

  void _validatePercentRuns(String value) {
    var index = 0;
    while (index < value.length) {
      if (value.codeUnitAt(index) != 0x25) {
        index++;
        continue;
      }
      final bytes = <int>[];
      while (index < value.length && value.codeUnitAt(index) == 0x25) {
        if (index + 2 >= value.length) throw _invalidPercent;
        final high = _hex(value.codeUnitAt(index + 1));
        final low = _hex(value.codeUnitAt(index + 2));
        if (high < 0 || low < 0) throw _invalidPercent;
        bytes.add((high << 4) | low);
        index += 3;
      }
      final String decoded;
      try {
        decoded = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        throw _invalidPercent;
      }
      for (final rune in decoded.runes) {
        if (rune <= 0x1f ||
            rune == 0x5c ||
            rune == 0x7f ||
            (rune >= 0x80 && rune <= 0x9f)) {
          throw _invalidPercent;
        }
      }
    }
  }

  int _hex(int unit) {
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
    if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
    if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
    return -1;
  }

  int _firstDelimiter(String value) {
    var result = value.length;
    for (final delimiter in ['/', '?', '#']) {
      final index = value.indexOf(delimiter);
      if (index >= 0 && index < result) result = index;
    }
    return result;
  }

  _CanonicalAuthority _canonicalAuthority(String authority) {
    if (authority.startsWith('[')) {
      final close = authority.indexOf(']');
      if (close <= 1 ||
          authority.indexOf('[', 1) >= 0 ||
          authority.indexOf(']', close + 1) >= 0) {
        throw _invalidHost;
      }
      final literal = authority.substring(1, close);
      if (literal.contains('%')) throw _invalidHost;
      final tail = authority.substring(close + 1);
      return _CanonicalAuthority(
        '[${_canonicalIpv6(literal)}]',
        tail.isEmpty ? null : _canonicalPortTail(tail),
      );
    }

    if (authority.contains('[') || authority.contains(']')) throw _invalidHost;
    final colon = authority.lastIndexOf(':');
    if (colon >= 0 && authority.indexOf(':') != colon) throw _invalidHost;
    final rawHost = colon < 0 ? authority : authority.substring(0, colon);
    final rawPort = colon < 0 ? null : authority.substring(colon + 1);
    return _CanonicalAuthority(
      _canonicalDnsOrIpv4(rawHost),
      rawPort == null ? null : _canonicalPort(rawPort),
    );
  }

  String _canonicalDnsOrIpv4(String host) {
    if (host.isEmpty ||
        host.contains('%') ||
        host.endsWith('.') ||
        host.length > 253) {
      throw _invalidHost;
    }
    if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
      final parts = host.split('.');
      if (parts.length != 4) throw _invalidHost;
      for (final part in parts) {
        if (part.isEmpty ||
            (part.length > 1 && part.startsWith('0')) ||
            !RegExp(r'^\d+$').hasMatch(part)) {
          throw _invalidHost;
        }
        final number = int.tryParse(part);
        if (number == null || number > 255) throw _invalidHost;
      }
      return parts.join('.');
    }
    if (RegExp(
      r'^(?:0[xX][0-9A-Fa-f]+|[0-9]+)(?:\.(?:0[xX][0-9A-Fa-f]+|[0-9]+))*$',
    ).hasMatch(host)) {
      throw _invalidHost;
    }
    final labels = host.split('.');
    for (final label in labels) {
      if (label.isEmpty ||
          label.length > 63 ||
          !RegExp(
            r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$',
          ).hasMatch(label)) {
        throw _invalidHost;
      }
    }
    return labels.map((label) => label.toLowerCase()).join('.');
  }

  int? _canonicalPortTail(String tail) {
    if (!tail.startsWith(':')) throw _invalidPort;
    return _canonicalPort(tail.substring(1));
  }

  int? _canonicalPort(String value) {
    if (value.isEmpty || !RegExp(r'^\d+$').hasMatch(value)) {
      throw _invalidPort;
    }
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) throw _invalidPort;
    return port == 443 ? null : port;
  }

  String _canonicalIpv6(String input) {
    if (input.isEmpty || input.split('::').length > 2) throw _invalidHost;
    final compressed = input.contains('::');
    final sides = input.split('::');
    final left = _parseIpv6Side(sides.first, allowIpv4: !compressed);
    final right = compressed
        ? _parseIpv6Side(sides[1], allowIpv4: true)
        : const <int>[];
    final supplied = left.length + right.length;
    if ((!compressed && supplied != 8) || (compressed && supplied >= 8)) {
      throw _invalidHost;
    }
    final words = <int>[
      ...left,
      if (compressed) ...List<int>.filled(8 - supplied, 0),
      ...right,
    ];
    var bestStart = -1;
    var bestLength = 0;
    for (var index = 0; index < words.length;) {
      if (words[index] != 0) {
        index++;
        continue;
      }
      var end = index;
      while (end < words.length && words[end] == 0) {
        end++;
      }
      final length = end - index;
      if (length >= 2 && length > bestLength) {
        bestStart = index;
        bestLength = length;
      }
      index = end;
    }
    if (bestStart < 0) {
      return words.map((word) => word.toRadixString(16)).join(':');
    }
    final before = words
        .take(bestStart)
        .map((word) => word.toRadixString(16))
        .join(':');
    final after = words
        .skip(bestStart + bestLength)
        .map((word) => word.toRadixString(16))
        .join(':');
    return '$before::$after';
  }

  List<int> _parseIpv6Side(String side, {required bool allowIpv4}) {
    if (side.isEmpty) return const [];
    final tokens = side.split(':');
    final words = <int>[];
    for (var index = 0; index < tokens.length; index++) {
      final token = tokens[index];
      if (token.isEmpty) throw _invalidHost;
      if (token.contains('.')) {
        if (!allowIpv4 || index != tokens.length - 1) throw _invalidHost;
        final ipv4 = _canonicalDnsOrIpv4(
          token,
        ).split('.').map(int.parse).toList(growable: false);
        words.add((ipv4[0] << 8) | ipv4[1]);
        words.add((ipv4[2] << 8) | ipv4[3]);
      } else {
        if (token.length > 4 || !RegExp(r'^[0-9A-Fa-f]+$').hasMatch(token)) {
          throw _invalidHost;
        }
        words.add(int.parse(token, radix: 16));
      }
    }
    return words;
  }

  void _validatePath(String suffix) {
    final query = suffix.indexOf('?');
    final fragment = suffix.indexOf('#');
    var end = suffix.length;
    if (query >= 0 && query < end) end = query;
    if (fragment >= 0 && fragment < end) end = fragment;
    final path = suffix.substring(0, end);
    if (path.isEmpty) return;
    for (final segment in path.split('/')) {
      final comparable = segment.replaceAll(
        RegExp('%2e', caseSensitive: false),
        '.',
      );
      if (comparable == '.' || comparable == '..') {
        throw const ExternalReferenceUrlException(
          ExternalReferenceUrlFailure.unsafePath,
          'The address cannot contain dot path segments.',
        );
      }
    }
  }

  static const _invalidCharacters = ExternalReferenceUrlException(
    ExternalReferenceUrlFailure.invalidCharacters,
    'The address contains unsupported characters.',
  );
  static const _invalidPercent = ExternalReferenceUrlException(
    ExternalReferenceUrlFailure.invalidPercentEncoding,
    'The address contains invalid percent encoding.',
  );
  static const _invalidHost = ExternalReferenceUrlException(
    ExternalReferenceUrlFailure.invalidHost,
    'The address host is invalid.',
  );
  static const _invalidPort = ExternalReferenceUrlException(
    ExternalReferenceUrlFailure.invalidPort,
    'The address port is invalid.',
  );
}

class _CanonicalAuthority {
  const _CanonicalAuthority(this.host, this.port);
  final String host;
  final int? port;
}
