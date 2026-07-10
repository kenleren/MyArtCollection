import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const brokerPayloadContractVersion = 'art-research-payload-v1';
const brokerCanonicalPayloadVersion = 'canonical-payload-v1';
const brokerApprovedPayloadClass = 'image_only_or_image_plus_draft_hints';

enum BrokerConsentScope {
  imageOnly('image_only'),
  imagePlusDraftHints('image_plus_draft_hints');

  const BrokerConsentScope(this.wireValue);

  final String wireValue;
}

/// The stable, typed consent protocol owned by #188. Presentation code can
/// choose how it renders this value, but cannot alter its wire semantics.
class BrokerResearchConsent {
  const BrokerResearchConsent.approved({
    required this.scope,
    required this.copyVersion,
  });

  final BrokerConsentScope scope;
  final String copyVersion;

  String get status => 'approved';
}

class BrokerDraftHints {
  const BrokerDraftHints({
    this.titleHint,
    this.artistHint,
    this.searchTerms = const [],
  });

  final String? titleHint;
  final String? artistHint;
  final List<String> searchTerms;

  Map<String, Object?> toJson() {
    final result = <String, Object?>{};
    final title = _safeHint(titleHint);
    final artist = _safeHint(artistHint);
    final terms = searchTerms
        .map(_safeHint)
        .whereType<String>()
        .take(5)
        .toList(growable: false);
    if (title != null) {
      result['title_hint'] = title;
    }
    if (artist != null) {
      result['artist_hint'] = artist;
    }
    if (terms.isNotEmpty) {
      result['search_terms'] = terms;
    }
    return result;
  }
}

class BrokerImageDerivative {
  const BrokerImageDerivative({
    required this.bytes,
    required this.longEdgePx,
    this.mimeType = 'image/jpeg',
  });

  final Uint8List bytes;
  final int longEdgePx;
  final String mimeType;
}

class BrokerRequestPayload {
  BrokerRequestPayload({
    required this.requestId,
    required this.consent,
    required this.derivative,
    this.draftHints,
  }) {
    _validate();
  }

  final String requestId;
  final BrokerResearchConsent consent;
  final BrokerImageDerivative derivative;
  final BrokerDraftHints? draftHints;

  factory BrokerRequestPayload.create({
    required BrokerResearchConsent consent,
    required BrokerImageDerivative derivative,
    BrokerDraftHints? draftHints,
    String? requestId,
  }) {
    return BrokerRequestPayload(
      requestId: requestId ?? _newRequestId(),
      consent: consent,
      derivative: derivative,
      draftHints: draftHints,
    );
  }

  Map<String, Object?> toRequest() {
    final hints = draftHints?.toJson();
    if (consent.scope == BrokerConsentScope.imageOnly &&
        hints != null &&
        hints.isNotEmpty) {
      throw ArgumentError('image_only consent cannot include draft hints.');
    }
    final request = <String, Object?>{
      'request_id': requestId,
      'consent_status': consent.status,
      'consent_scope': consent.scope.wireValue,
      'consent_copy_version': consent.copyVersion,
      'payload_contract_version': brokerPayloadContractVersion,
      'approved_payload_class': brokerApprovedPayloadClass,
      'image': <String, Object?>{
        'mime_type': derivative.mimeType,
        'byte_size': derivative.bytes.lengthInBytes,
        'long_edge_px': derivative.longEdgePx,
        'content_base64': base64Encode(derivative.bytes),
      },
      if (hints != null && hints.isNotEmpty) 'draft_hints': hints,
    };
    return <String, Object?>{
      ...request,
      'payload_hash': sha256
          .convert(
            utf8.encode(
              canonicalPayloadJson(canonicalBrokerPayloadDocument(request)),
            ),
          )
          .toString(),
    };
  }

  void _validate() {
    if (!_isUuid(requestId)) {
      throw ArgumentError.value(requestId, 'requestId', 'must be a UUID.');
    }
    if (consent.copyVersion.isEmpty ||
        _containsLoneSurrogate(consent.copyVersion)) {
      throw ArgumentError.value(
        consent.copyVersion,
        'copyVersion',
        'must be valid Unicode.',
      );
    }
    if (derivative.mimeType != 'image/jpeg' &&
        derivative.mimeType != 'image/webp') {
      throw ArgumentError.value(
        derivative.mimeType,
        'mimeType',
        'must be JPEG or WebP.',
      );
    }
    if (derivative.bytes.isEmpty || derivative.bytes.lengthInBytes > 1500000) {
      throw ArgumentError.value(
        derivative.bytes.lengthInBytes,
        'bytes',
        'must be at most 1.5MB.',
      );
    }
    if (derivative.longEdgePx <= 0 || derivative.longEdgePx > 1600) {
      throw ArgumentError.value(
        derivative.longEdgePx,
        'longEdgePx',
        'must be at most 1600.',
      );
    }
  }
}

/// Builds the #187 hash document. The transport request intentionally does not
/// carry [brokerCanonicalPayloadVersion], but the broker includes it in the
/// RFC 8785 hash domain.
Map<String, Object?> canonicalBrokerPayloadDocument(
  Map<String, Object?> request,
) {
  return <String, Object?>{
    'canonical_payload_version': brokerCanonicalPayloadVersion,
    for (final entry in request.entries)
      if (entry.key != 'request_id' && entry.key != 'payload_hash')
        entry.key: entry.value,
  };
}

/// RFC 8785 canonical JSON for this contract's JSON-only values.
String canonicalPayloadJson(Object? value) {
  if (value == null || value is bool || value is num) {
    if (value is num && !value.isFinite) {
      throw ArgumentError('Non-finite numbers are not valid JSON.');
    }
    return jsonEncode(value);
  }
  if (value is String) {
    _requireValidUnicode(value);
    return jsonEncode(value);
  }
  if (value is List<Object?>) {
    return '[${value.map(canonicalPayloadJson).join(',')}]';
  }
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return '{${keys.map((key) {
      _requireValidUnicode(key);
      final child = value[key];
      if (child == null && !value.containsKey(key)) {
        throw ArgumentError('Canonical JSON cannot contain undefined values.');
      }
      return '${jsonEncode(key)}:${canonicalPayloadJson(child)}';
    }).join(',')}}';
  }
  throw ArgumentError('Canonical JSON supports only JSON values.');
}

String _newRequestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _isUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(value);

String? _safeHint(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  _requireValidUnicode(normalized);
  return normalized.length <= 160 ? normalized : normalized.substring(0, 160);
}

void _requireValidUnicode(String value) {
  if (_containsLoneSurrogate(value)) {
    throw ArgumentError.value(
      value,
      'value',
      'must not contain a lone surrogate.',
    );
  }
}

bool _containsLoneSurrogate(String value) {
  for (var index = 0; index < value.length; index += 1) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= value.length) {
        return true;
      }
      final next = value.codeUnitAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) {
        return true;
      }
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return true;
    }
  }
  return false;
}
