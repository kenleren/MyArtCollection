import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../config/app_feature_flags.dart';
import 'broker_payload.dart';
import 'firebase_research_runtime.dart';

class BrokerTransportResponse {
  const BrokerTransportResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

abstract interface class BrokerHttpTransport {
  Future<BrokerTransportResponse> post({
    required Uri endpoint,
    required Map<String, String> headers,
    required String body,
  });
}

class DartIoBrokerHttpTransport implements BrokerHttpTransport {
  DartIoBrokerHttpTransport({HttpClient? client})
    : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<BrokerTransportResponse> post({
    required Uri endpoint,
    required Map<String, String> headers,
    required String body,
  }) async {
    final request = await _client.postUrl(endpoint);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.write(body);
    final response = await request.close();
    return BrokerTransportResponse(
      statusCode: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  }
}

abstract interface class BrokerConnectivity {
  Future<bool> isAvailable(Uri endpoint);
}

class EndpointDnsBrokerConnectivity implements BrokerConnectivity {
  const EndpointDnsBrokerConnectivity();

  @override
  Future<bool> isAvailable(Uri endpoint) async {
    try {
      return (await InternetAddress.lookup(endpoint.host)).isNotEmpty;
    } on SocketException {
      return false;
    }
  }
}

class FrozenBrokerRequest {
  const FrozenBrokerRequest({
    required this.requestId,
    required this.payloadHash,
    required this.body,
    required this.consent,
    this.retentionExpiresAt,
  });

  final String requestId;
  final String payloadHash;
  final String body;
  final BrokerResearchConsent consent;
  final DateTime? retentionExpiresAt;

  bool matchesConsent(BrokerResearchConsent currentConsent) {
    return consent.scope == currentConsent.scope &&
        consent.copyVersion == currentConsent.copyVersion;
  }
}

abstract interface class BrokerRetryStore {
  Future<void> save(FrozenBrokerRequest request);

  Future<FrozenBrokerRequest?> read(String requestId);

  Future<void> clear(String requestId);
}

class FileBrokerRetryStore implements BrokerRetryStore {
  const FileBrokerRetryStore._(this._directory, this._now);

  final Directory _directory;
  final DateTime Function() _now;
  static const retentionDuration = Duration(hours: 24);

  static Future<FileBrokerRetryStore> open() async {
    final root = await getApplicationSupportDirectory();
    return openAt(
      Directory(path.join(root.path, 'research-retry')),
      deleteOrphansOnOpen: true,
    );
  }

  static Future<FileBrokerRetryStore> openAt(
    Directory directory, {
    DateTime Function()? now,
    bool deleteOrphansOnOpen = false,
  }) async {
    await directory.create(recursive: true);
    final store = FileBrokerRetryStore._(directory, now ?? DateTime.now);
    if (deleteOrphansOnOpen) {
      await store.clearAll();
    } else {
      await store.deleteExpired();
    }
    return store;
  }

  @override
  Future<void> save(FrozenBrokerRequest request) async {
    final retainedAt = _now().toUtc();
    final maximumExpiry = retainedAt.add(retentionDuration);
    final requestedExpiry = request.retentionExpiresAt?.toUtc();
    final expiresAt =
        requestedExpiry == null || requestedExpiry.isAfter(maximumExpiry)
        ? maximumExpiry
        : requestedExpiry;
    final destination = _fileFor(request.requestId);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, String>{
        'request_id': request.requestId,
        'payload_hash': request.payloadHash,
        'body': request.body,
        'consent_scope': request.consent.scope.wireValue,
        'consent_copy_version': request.consent.copyVersion,
        'retention_started_at': retainedAt.toIso8601String(),
        'retention_expires_at': expiresAt.toIso8601String(),
      }),
      flush: true,
    );
    await temporary.rename(destination.path);
  }

  @override
  Future<FrozenBrokerRequest?> read(String requestId) async {
    final file = _fileFor(requestId);
    if (!await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<Object?, Object?> ||
          decoded.keys.any(
            (key) => key is! String || !_frozenStorageKeys.contains(key),
          ) ||
          decoded['request_id'] != requestId ||
          decoded['payload_hash'] is! String ||
          decoded['body'] is! String ||
          decoded['consent_scope'] is! String ||
          decoded['consent_copy_version'] is! String ||
          decoded['retention_started_at'] is! String ||
          decoded['retention_expires_at'] is! String) {
        await _deleteIfPresent(file);
        return null;
      }
      final retainedAt = _strictUtcTimestamp(
        decoded['retention_started_at']! as String,
      );
      final expiresAt = _strictUtcTimestamp(
        decoded['retention_expires_at']! as String,
      );
      final now = _now().toUtc();
      if (retainedAt == null ||
          expiresAt == null ||
          retainedAt.isAfter(now) ||
          !expiresAt.isAfter(now) ||
          expiresAt.isAfter(retainedAt.add(retentionDuration))) {
        await _deleteIfPresent(file);
        return null;
      }
      final scope = _consentScopeFromWire(decoded['consent_scope']! as String);
      if (scope == null) {
        await _deleteIfPresent(file);
        return null;
      }
      return FrozenBrokerRequest(
        requestId: requestId,
        payloadHash: decoded['payload_hash']! as String,
        body: decoded['body']! as String,
        consent: BrokerResearchConsent.approved(
          scope: scope,
          copyVersion: decoded['consent_copy_version']! as String,
        ),
        retentionExpiresAt: expiresAt,
      );
    } on Object {
      await _deleteIfPresent(file);
      return null;
    }
  }

  @override
  Future<void> clear(String requestId) async {
    final file = _fileFor(requestId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> clearAll() async {
    await for (final entity in _directory.list()) {
      if (entity is File &&
          (entity.path.endsWith('.json') || entity.path.endsWith('.tmp'))) {
        await _deleteIfPresent(entity);
      }
    }
  }

  Future<void> deleteExpired() async {
    await for (final entity in _directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      final requestId = path.basenameWithoutExtension(entity.path);
      try {
        await read(requestId);
      } on ArgumentError {
        await _deleteIfPresent(entity);
      }
    }
  }

  Future<void> _deleteIfPresent(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  File _fileFor(String requestId) {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(requestId)) {
      throw ArgumentError.value(
        requestId,
        'requestId',
        'must be a UUID filename.',
      );
    }
    return File(path.join(_directory.path, '$requestId.json'));
  }
}

const _frozenStorageKeys = <String>{
  'request_id',
  'payload_hash',
  'body',
  'consent_scope',
  'consent_copy_version',
  'retention_started_at',
  'retention_expires_at',
};

DateTime? _strictUtcTimestamp(String value) {
  if (!RegExp(r'(?:Z|[+-][0-9]{2}:[0-9]{2})$').hasMatch(value)) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

class BrokerClientFailure {
  const BrokerClientFailure({
    required this.code,
    required this.message,
    this.retryAfterSeconds,
    this.retryable = false,
  });

  final String code;
  final String message;
  final int? retryAfterSeconds;
  final bool retryable;
}

class BrokerClientResult {
  const BrokerClientResult.success(
    this.response, {
    this.refreshedAfterUnauthorized = false,
  }) : failure = null;

  const BrokerClientResult.failure(
    this.failure, {
    this.refreshedAfterUnauthorized = false,
  }) : response = null;

  final BrokerSuccessResponse? response;
  final BrokerClientFailure? failure;
  final bool refreshedAfterUnauthorized;

  bool get isSuccess => response != null;
}

/// A consent-gated, broker-only HTTP client. It never contacts a provider and
/// leaves a frozen request only after a transport failure for explicit retry.
class BrokerHttpClient {
  BrokerHttpClient({
    required this.endpoint,
    required this.featureFlags,
    required this.firebaseRuntime,
    required this.transport,
    required this.connectivity,
    required this.retryStore,
  });

  final Uri endpoint;
  final AppFeatureFlagService featureFlags;
  final FirebaseResearchRuntime firebaseRuntime;
  final BrokerHttpTransport transport;
  final BrokerConnectivity connectivity;
  final BrokerRetryStore retryStore;
  final Set<String> _activeRequestIds = <String>{};

  Future<BrokerClientFailure?> _gateAfterConsent() async {
    if (!featureFlags.isConfiguredBrokerEndpoint(endpoint)) {
      return const BrokerClientFailure(
        code: 'endpoint_unavailable',
        message: 'Research is unavailable.',
      );
    }
    if (!featureFlags.localResearchCapabilityEnabled) {
      return const BrokerClientFailure(
        code: 'research_disabled',
        message: 'Research is unavailable.',
      );
    }
    AppFeatureFlags flags;
    try {
      flags = await featureFlags.loadAfterConsent();
    } on Object {
      return const BrokerClientFailure(
        code: 'research_disabled',
        message: 'Research is unavailable.',
      );
    }
    if (!flags.onlineResearchEnabled) {
      return const BrokerClientFailure(
        code: 'research_disabled',
        message: 'Research is unavailable.',
      );
    }
    return null;
  }

  /// Runs one consent-bound submission. Payload preparation happens only after
  /// both gates pass, so no artwork/file/derivative operation can reuse a
  /// preauthorization decision.
  Future<BrokerClientResult> submitAfterConsent({
    required String requestId,
    required BrokerResearchConsent consent,
    required Future<BrokerRequestPayload?> Function() preparePayload,
  }) async {
    if (!_beginOperation(requestId)) return _inFlightFailure();
    try {
      final gateFailure = await _gateAfterConsent();
      if (gateFailure != null) return BrokerClientResult.failure(gateFailure);
      final payload = await preparePayload();
      if (payload == null) {
        return const BrokerClientResult.failure(
          BrokerClientFailure(
            code: 'image_unavailable',
            message: 'The selected image could not be prepared for research.',
          ),
        );
      }
      if (payload.requestId != requestId ||
          !_matchesConsent(payload.consent, consent)) {
        return const BrokerClientResult.failure(
          BrokerClientFailure(
            code: 'consent_required',
            message: 'Research consent must be confirmed again.',
          ),
        );
      }
      final request = payload.toRequest();
      final frozen = FrozenBrokerRequest(
        requestId: requestId,
        payloadHash: request['payload_hash']! as String,
        body: jsonEncode(<String, Object?>{'data': request}),
        consent: consent,
      );
      return _submitFrozen(frozen, saveBeforeSend: true);
    } on Object {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'image_unavailable',
          message: 'The selected image could not be prepared for research.',
        ),
      );
    } finally {
      _endOperation(requestId);
    }
  }

  /// Replays only a retained, byte-identical request after fresh consent and
  /// both current gates pass. A request ID has at most one active operation.
  Future<BrokerClientResult> retryAfterConsent(
    String requestId, {
    required BrokerResearchConsent consent,
  }) async {
    if (!_beginOperation(requestId)) return _inFlightFailure();
    try {
      final gateFailure = await _gateAfterConsent();
      if (gateFailure != null) return BrokerClientResult.failure(gateFailure);
      final frozen = await retryStore.read(requestId);
      if (frozen == null || !_matchesFrozenRequest(frozen)) {
        return const BrokerClientResult.failure(
          BrokerClientFailure(
            code: 'retry_not_available',
            message: 'No saved research request is available.',
          ),
        );
      }
      if (!frozen.matchesConsent(consent)) {
        return const BrokerClientResult.failure(
          BrokerClientFailure(
            code: 'consent_required',
            message: 'Research consent must be confirmed again.',
          ),
        );
      }
      return _submitFrozen(frozen, saveBeforeSend: false);
    } finally {
      _endOperation(requestId);
    }
  }

  Future<BrokerClientResult> cancel(String requestId) async {
    await retryStore.clear(requestId);
    return const BrokerClientResult.failure(
      BrokerClientFailure(
        code: 'cancelled',
        message: 'The research request was cancelled.',
      ),
    );
  }

  bool _beginOperation(String requestId) => _activeRequestIds.add(requestId);

  void _endOperation(String requestId) => _activeRequestIds.remove(requestId);

  BrokerClientResult _inFlightFailure() => const BrokerClientResult.failure(
    BrokerClientFailure(
      code: 'request_in_flight',
      message: 'Research is already in progress.',
      retryable: true,
    ),
  );

  Future<BrokerClientResult> _submitFrozen(
    FrozenBrokerRequest frozen, {
    required bool saveBeforeSend,
  }) async {
    if (!_matchesFrozenRequest(frozen)) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'retry_not_available',
          message: 'No saved research request is available.',
        ),
      );
    }
    try {
      await firebaseRuntime.initializeAppCheck();
      await firebaseRuntime.signInAnonymously();
    } on Object {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'identity_unavailable',
          message: 'Research is unavailable.',
        ),
      );
    }

    final connected = await _isConnected();
    if (!connected) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'offline',
          message: 'Research needs a connection.',
        ),
      );
    }

    if (saveBeforeSend) {
      try {
        await retryStore.save(frozen);
      } on Object {
        return const BrokerClientResult.failure(
          BrokerClientFailure(
            code: 'retry_storage_unavailable',
            message: 'Research is temporarily unavailable.',
          ),
        );
      }
    }
    return _sendWithOneUnauthorizedRefresh(frozen);
  }

  Future<bool> _isConnected() async {
    try {
      return await connectivity.isAvailable(endpoint);
    } on Object {
      return false;
    }
  }

  Future<BrokerClientResult> _sendWithOneUnauthorizedRefresh(
    FrozenBrokerRequest frozen,
  ) async {
    final initial = await _sendAttempt(frozen, forceRefresh: false);
    if (initial is _BrokerTransportFailure) {
      return BrokerClientResult.failure(initial.failure);
    }
    final initialResponse = (initial as _BrokerTransportSuccess).response;
    if (initialResponse.statusCode != 401) {
      return _finishTerminal(frozen, initialResponse);
    }

    final refreshed = await _sendAttempt(frozen, forceRefresh: true);
    if (refreshed is _BrokerTransportFailure) {
      return BrokerClientResult.failure(
        refreshed.failure,
        refreshedAfterUnauthorized: true,
      );
    }
    return _finishTerminal(
      frozen,
      (refreshed as _BrokerTransportSuccess).response,
      refreshedAfterUnauthorized: true,
    );
  }

  Future<_BrokerAttempt> _sendAttempt(
    FrozenBrokerRequest frozen, {
    required bool forceRefresh,
  }) async {
    try {
      final authToken = await firebaseRuntime.authToken(
        forceRefresh: forceRefresh,
      );
      final appCheckToken = await firebaseRuntime.limitedUseAppCheckToken(
        forceRefresh: forceRefresh,
      );
      if (authToken == null ||
          authToken.isEmpty ||
          appCheckToken == null ||
          appCheckToken.isEmpty) {
        return const _BrokerTransportFailure(
          BrokerClientFailure(
            code: 'token_unavailable',
            message: 'Research is unavailable.',
          ),
        );
      }
      final response = await transport.post(
        endpoint: endpoint,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $authToken',
          'X-Firebase-AppCheck': appCheckToken,
        },
        body: frozen.body,
      );
      return _BrokerTransportSuccess(response);
    } on Object {
      return const _BrokerTransportFailure(
        BrokerClientFailure(
          code: 'transport_unavailable',
          message: 'Research is temporarily unavailable.',
        ),
      );
    }
  }

  Future<BrokerClientResult> _finishTerminal(
    FrozenBrokerRequest frozen,
    BrokerTransportResponse transportResponse, {
    bool refreshedAfterUnauthorized = false,
  }) async {
    final body = _jsonObject(transportResponse.body);
    final success = body == null
        ? null
        : BrokerSuccessResponse.tryParse(body, frozen.requestId);
    if (transportResponse.statusCode == 200 && success != null) {
      await retryStore.clear(frozen.requestId);
      return BrokerClientResult.success(
        success,
        refreshedAfterUnauthorized: refreshedAfterUnauthorized,
      );
    }
    final failure = _safeBrokerFailure(
      body,
      requestId: frozen.requestId,
      httpStatus: transportResponse.statusCode,
    );
    if (!_retainsFrozenRequest(failure.code)) {
      await retryStore.clear(frozen.requestId);
    }
    return BrokerClientResult.failure(
      failure,
      refreshedAfterUnauthorized: refreshedAfterUnauthorized,
    );
  }
}

bool _retainsFrozenRequest(String code) => code == 'request_in_flight';

sealed class _BrokerAttempt {
  const _BrokerAttempt();
}

class _BrokerTransportSuccess extends _BrokerAttempt {
  const _BrokerTransportSuccess(this.response);

  final BrokerTransportResponse response;
}

class _BrokerTransportFailure extends _BrokerAttempt {
  const _BrokerTransportFailure(this.failure);

  final BrokerClientFailure failure;
}

Map<String, Object?>? _jsonObject(String input) {
  try {
    final decoded = jsonDecode(input);
    if (decoded is Map<Object?, Object?>) {
      return Map<String, Object?>.from(decoded);
    }
  } on FormatException {
    // Invalid broker responses are intentionally mapped to a generic failure.
  }
  return null;
}

BrokerClientFailure _safeBrokerFailure(
  Map<String, Object?>? body, {
  required String requestId,
  required int httpStatus,
}) {
  if (!_isBrokerErrorEnvelope(
    body,
    requestId: requestId,
    httpStatus: httpStatus,
  )) {
    return const BrokerClientFailure(
      code: 'invalid_broker_response',
      message: 'Research is temporarily unavailable.',
    );
  }
  final error = Map<String, Object?>.from(body!['error']! as Map);
  final retryAfter = error['retry_after_seconds'];
  return BrokerClientFailure(
    code: error['code']! as String,
    message: 'Research is temporarily unavailable.',
    retryable: error['retryable']! as bool,
    retryAfterSeconds: retryAfter is int && retryAfter >= 5 && retryAfter <= 300
        ? retryAfter
        : null,
  );
}

bool _matchesFrozenRequest(FrozenBrokerRequest frozen) {
  return isValidFrozenBrokerRequest(
    body: frozen.body,
    requestId: frozen.requestId,
    payloadHash: frozen.payloadHash,
    consent: frozen.consent,
  );
}

bool _matchesConsent(
  BrokerResearchConsent first,
  BrokerResearchConsent second,
) => first.scope == second.scope && first.copyVersion == second.copyVersion;

class _BrokerErrorTuple {
  const _BrokerErrorTuple(
    this.httpStatus,
    this.status,
    this.code,
    this.message,
    this.retryable, [
    this.retryAfterSeconds,
  ]);

  final int httpStatus;
  final String status;
  final String code;
  final String message;
  final bool retryable;
  final int? retryAfterSeconds;

  bool matches({
    required int responseHttpStatus,
    required String responseStatus,
    required String responseCode,
    required String responseMessage,
    required bool responseRetryable,
    required int? responseRetryAfterSeconds,
  }) =>
      httpStatus == responseHttpStatus &&
      status == responseStatus &&
      code == responseCode &&
      message == responseMessage &&
      retryable == responseRetryable &&
      retryAfterSeconds == responseRetryAfterSeconds;
}

// Derived from backend/broker/fixtures/broker-error-v1.json. This is a
// closed protocol surface: a valid field from one fixture case cannot be
// combined with fields from another case.
const _brokerErrorTuples = <_BrokerErrorTuple>[
  _BrokerErrorTuple(
    400,
    'rejected',
    'payload_invalid',
    'The request payload is invalid.',
    false,
  ),
  _BrokerErrorTuple(
    401,
    'rejected',
    'unauthorized',
    'Authentication could not be verified.',
    false,
  ),
  _BrokerErrorTuple(
    401,
    'rejected',
    'unauthorized',
    'Authentication could not be verified.',
    true,
  ),
  _BrokerErrorTuple(
    402,
    'rejected',
    'credits_exhausted',
    'No online research credits remain.',
    false,
  ),
  _BrokerErrorTuple(
    403,
    'rejected',
    'consent_required',
    'Approved research consent is required.',
    false,
  ),
  _BrokerErrorTuple(
    403,
    'rejected',
    'consent_stale',
    'Research consent must be refreshed.',
    false,
  ),
  _BrokerErrorTuple(
    403,
    'rejected',
    'forbidden',
    'This request is not allowed.',
    false,
  ),
  _BrokerErrorTuple(
    403,
    'rejected',
    'not_entitled',
    'Online research is not included for this account.',
    false,
  ),
  _BrokerErrorTuple(
    405,
    'rejected',
    'method_not_allowed',
    'Only POST requests are accepted.',
    false,
  ),
  _BrokerErrorTuple(
    409,
    'conflict',
    'idempotency_conflict',
    'The request ID was already used for a different payload.',
    false,
  ),
  _BrokerErrorTuple(
    409,
    'conflict',
    'request_expired',
    'The prior request expired before provider dispatch.',
    false,
  ),
  _BrokerErrorTuple(
    409,
    'conflict',
    'request_in_flight',
    'A research request is already in progress.',
    true,
    5,
  ),
  _BrokerErrorTuple(
    409,
    'conflict',
    'request_outcome_unknown',
    'The prior request outcome cannot be safely retried.',
    false,
  ),
  _BrokerErrorTuple(
    413,
    'rejected',
    'payload_too_large',
    'The image payload is too large.',
    false,
  ),
  _BrokerErrorTuple(
    415,
    'rejected',
    'unsupported_media_type',
    'Content-Type must be application/json.',
    false,
  ),
  _BrokerErrorTuple(
    415,
    'rejected',
    'unsupported_media_type',
    'The image media type is not supported.',
    false,
  ),
  _BrokerErrorTuple(
    429,
    'rejected',
    'rate_limited',
    'The research service is busy. Try again later.',
    true,
    30,
  ),
  _BrokerErrorTuple(
    502,
    'rejected',
    'upstream_failure',
    'The research provider could not complete the request.',
    false,
  ),
  _BrokerErrorTuple(
    502,
    'rejected',
    'upstream_invalid_output',
    'The research result did not pass validation.',
    false,
  ),
  _BrokerErrorTuple(
    502,
    'rejected',
    'upstream_refusal',
    'The research provider declined this request.',
    false,
  ),
  _BrokerErrorTuple(
    503,
    'rejected',
    'temporarily_unavailable',
    'Research is temporarily unavailable.',
    false,
  ),
  _BrokerErrorTuple(
    503,
    'rejected',
    'temporarily_unavailable',
    'Research is temporarily unavailable.',
    true,
    5,
  ),
  _BrokerErrorTuple(
    503,
    'rejected',
    'temporarily_unavailable',
    'Research is temporarily unavailable.',
    true,
    30,
  ),
  _BrokerErrorTuple(
    504,
    'rejected',
    'upstream_timeout',
    'The research provider did not finish in time.',
    false,
  ),
];

bool _isBrokerErrorEnvelope(
  Map<String, Object?>? body, {
  required String requestId,
  required int httpStatus,
}) {
  if (body == null ||
      !_hasOnlyKeys(body, const {
        'ok',
        'error_contract_version',
        'request_id',
        'status',
        'error',
      }) ||
      body['ok'] != false ||
      body['error_contract_version'] != 'broker-error-v1' ||
      (body.containsKey('request_id') && body['request_id'] != requestId) ||
      (body.containsKey('request_id') && !_isUuid(body['request_id'])) ||
      (body['status'] != 'rejected' && body['status'] != 'conflict')) {
    return false;
  }
  final error = _stringMap(body['error']);
  if (error == null ||
      !_hasOnlyKeys(error, const {
        'code',
        'message',
        'retryable',
        'retry_after_seconds',
      }) ||
      error['code'] is! String ||
      error['message'] is! String ||
      error['retryable'] is! bool) {
    return false;
  }
  final retryAfter = error['retry_after_seconds'];
  if (retryAfter != null &&
      (retryAfter is! int || retryAfter < 5 || retryAfter > 300)) {
    return false;
  }
  return _brokerErrorTuples.any(
    (tuple) => tuple.matches(
      responseHttpStatus: httpStatus,
      responseStatus: body['status']! as String,
      responseCode: error['code']! as String,
      responseMessage: error['message']! as String,
      responseRetryable: error['retryable']! as bool,
      responseRetryAfterSeconds: retryAfter as int?,
    ),
  );
}

BrokerConsentScope? _consentScopeFromWire(String value) {
  for (final scope in BrokerConsentScope.values) {
    if (scope.wireValue == value) {
      return scope;
    }
  }
  return null;
}

bool _isUuid(Object? value) =>
    value is String &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(value);

Map<String, Object?>? _stringMap(Object? value) {
  if (value is! Map<Object?, Object?> ||
      value.keys.any((key) => key is! String)) {
    return null;
  }
  return Map<String, Object?>.from(value);
}

bool _hasOnlyKeys(Map<String, Object?> value, Set<String> allowed) =>
    value.keys.every(allowed.contains);

class BrokerSuccessResponse {
  const BrokerSuccessResponse._({
    required this.requestId,
    required this.provider,
    required this.model,
    required this.reasoningEffort,
    required this.completedAt,
    required this.replayed,
    required this.sources,
    required this.candidateAttributions,
    required this.comparableValueSignals,
    required this.warnings,
  });

  final String requestId;
  final String provider;
  final String model;
  final String reasoningEffort;
  final DateTime completedAt;
  final bool replayed;
  final List<BrokerResearchSource> sources;
  final List<BrokerResearchCandidate> candidateAttributions;
  final List<BrokerComparableValueSignal> comparableValueSignals;
  final List<String> warnings;

  static BrokerSuccessResponse? tryParse(
    Map<String, Object?> value,
    String expectedRequestId,
  ) {
    if (!_hasOnlyKeys(value, const {
          'request_id',
          'status',
          'provider',
          'model',
          'reasoning_effort',
          'completed_at',
          'replayed',
          'sources',
          'candidate_attributions',
          'comparable_value_signals',
          'warnings',
        }) ||
        value['request_id'] != expectedRequestId ||
        value['status'] != 'completed' ||
        (value['provider'] != 'fake-provider' &&
            value['provider'] != 'openai') ||
        value['model'] is! String ||
        (value['model']! as String).isEmpty ||
        (value['reasoning_effort'] != 'none' &&
            value['reasoning_effort'] != 'medium' &&
            value['reasoning_effort'] != 'high' &&
            value['reasoning_effort'] != 'xhigh') ||
        value['completed_at'] is! String ||
        (value.containsKey('replayed') && value['replayed'] != true) ||
        value['sources'] is! List ||
        value['candidate_attributions'] is! List ||
        value['comparable_value_signals'] is! List ||
        value['warnings'] is! List) {
      return null;
    }
    final completedAt = DateTime.tryParse(value['completed_at']! as String);
    if (completedAt == null) {
      return null;
    }
    final sources = (value['sources']! as List)
        .map(BrokerResearchSource.tryParse)
        .toList(growable: false);
    if (sources.any((source) => source == null)) {
      return null;
    }
    final sourceIds = sources.map((source) => source!.sourceId).toSet();
    final candidates = (value['candidate_attributions']! as List)
        .map((entry) => BrokerResearchCandidate.tryParse(entry, sourceIds))
        .toList(growable: false);
    final signals = (value['comparable_value_signals']! as List)
        .map((entry) => BrokerComparableValueSignal.tryParse(entry, sourceIds))
        .toList(growable: false);
    final warnings = value['warnings']! as List;
    if (candidates.any((candidate) => candidate == null) ||
        signals.any((signal) => signal == null) ||
        warnings.any((warning) => warning is! String)) {
      return null;
    }
    return BrokerSuccessResponse._(
      requestId: expectedRequestId,
      provider: value['provider']! as String,
      model: value['model']! as String,
      reasoningEffort: value['reasoning_effort']! as String,
      completedAt: completedAt,
      replayed: value['replayed'] == true,
      sources: List.unmodifiable(sources.cast<BrokerResearchSource>()),
      candidateAttributions: List.unmodifiable(
        candidates.cast<BrokerResearchCandidate>(),
      ),
      comparableValueSignals: List.unmodifiable(
        signals.cast<BrokerComparableValueSignal>(),
      ),
      warnings: List.unmodifiable(warnings.cast<String>()),
    );
  }
}

class BrokerResearchSource {
  const BrokerResearchSource._({
    required this.sourceId,
    required this.sourceName,
    required this.sourceType,
    required this.sourceUrl,
    required this.title,
    required this.accessedAt,
    required this.citationExcerpt,
    required this.matchedFields,
  });

  final String sourceId;
  final String sourceName;
  final String sourceType;
  final String sourceUrl;
  final String title;
  final String accessedAt;
  final String citationExcerpt;
  final List<String> matchedFields;

  static BrokerResearchSource? tryParse(Object? value) {
    final source = _stringMap(value);
    if (source == null ||
        !_hasOnlyKeys(source, const {
          'source_id',
          'source_name',
          'source_type',
          'source_url',
          'title',
          'accessed_at',
          'citation_excerpt',
          'matched_fields',
        }) ||
        source['source_id'] is! String ||
        source['source_name'] is! String ||
        (source['source_type'] != 'museum' &&
            source['source_type'] != 'auction_house') ||
        source['source_url'] is! String ||
        !(source['source_url']! as String).startsWith('https://') ||
        source['title'] is! String ||
        source['accessed_at'] is! String ||
        source['citation_excerpt'] is! String ||
        source['matched_fields'] is! List) {
      return null;
    }
    final matchedFields = source['matched_fields']! as List;
    if (matchedFields.any((field) => field is! String)) {
      return null;
    }
    return BrokerResearchSource._(
      sourceId: source['source_id']! as String,
      sourceName: source['source_name']! as String,
      sourceType: source['source_type']! as String,
      sourceUrl: source['source_url']! as String,
      title: source['title']! as String,
      accessedAt: source['accessed_at']! as String,
      citationExcerpt: source['citation_excerpt']! as String,
      matchedFields: List.unmodifiable(matchedFields.cast<String>()),
    );
  }
}

class BrokerResearchCandidate {
  const BrokerResearchCandidate._({
    required this.candidateId,
    required this.confidence,
    required this.matchReason,
    required this.title,
    required this.artist,
    required this.year,
    required this.medium,
    required this.fieldSources,
    required this.sourceRefs,
  });

  final String candidateId;
  final String confidence;
  final String matchReason;
  final String? title;
  final String? artist;
  final String? year;
  final String? medium;
  final Map<String, String> fieldSources;
  final List<String> sourceRefs;

  static BrokerResearchCandidate? tryParse(
    Object? value,
    Set<String> sourceIds,
  ) {
    final candidate = _stringMap(value);
    if (candidate == null ||
        !_hasOnlyKeys(candidate, const {
          'candidate_id',
          'confidence',
          'match_reason',
          'title',
          'artist',
          'year',
          'medium',
          'field_sources',
          'source_refs',
        }) ||
        candidate['candidate_id'] is! String ||
        (candidate['confidence'] != 'possible' &&
            candidate['confidence'] != 'likely' &&
            candidate['confidence'] != 'insufficient_evidence') ||
        candidate['match_reason'] is! String ||
        !_isOptionalString(candidate, 'title') ||
        !_isOptionalString(candidate, 'artist') ||
        !_isOptionalString(candidate, 'year') ||
        !_isOptionalString(candidate, 'medium') ||
        candidate['source_refs'] is! List) {
      return null;
    }
    final fieldSources = _stringMap(candidate['field_sources']);
    final sourceRefs = candidate['source_refs']! as List;
    if (fieldSources == null ||
        fieldSources.values.any((source) => source != 'ai_suggested') ||
        sourceRefs.isEmpty ||
        sourceRefs.any(
          (source) => source is! String || !sourceIds.contains(source),
        )) {
      return null;
    }
    return BrokerResearchCandidate._(
      candidateId: candidate['candidate_id']! as String,
      confidence: candidate['confidence']! as String,
      matchReason: candidate['match_reason']! as String,
      title: candidate['title'] as String?,
      artist: candidate['artist'] as String?,
      year: candidate['year'] as String?,
      medium: candidate['medium'] as String?,
      fieldSources: Map.unmodifiable(fieldSources.cast<String, String>()),
      sourceRefs: List.unmodifiable(sourceRefs.cast<String>()),
    );
  }
}

class BrokerComparableValueSignal {
  const BrokerComparableValueSignal._({
    required this.kind,
    required this.label,
    required this.sourceRefs,
    required this.caveat,
  });

  final String kind;
  final String label;
  final List<String> sourceRefs;
  final String caveat;

  static BrokerComparableValueSignal? tryParse(
    Object? value,
    Set<String> sourceIds,
  ) {
    final signal = _stringMap(value);
    if (signal == null ||
        !_hasOnlyKeys(signal, const {
          'kind',
          'label',
          'source_refs',
          'caveat',
        }) ||
        (signal['kind'] != 'public_estimate' &&
            signal['kind'] != 'comparable_sale_signal' &&
            signal['kind'] != 'no_reliable_comparable') ||
        signal['label'] is! String ||
        signal['source_refs'] is! List ||
        signal['caveat'] is! String) {
      return null;
    }
    final sourceRefs = signal['source_refs']! as List;
    if (sourceRefs.any(
          (source) => source is! String || !sourceIds.contains(source),
        ) ||
        (signal['kind'] != 'no_reliable_comparable' && sourceRefs.isEmpty)) {
      return null;
    }
    return BrokerComparableValueSignal._(
      kind: signal['kind']! as String,
      label: signal['label']! as String,
      sourceRefs: List.unmodifiable(sourceRefs.cast<String>()),
      caveat: signal['caveat']! as String,
    );
  }
}

bool _isOptionalString(Map<String, Object?> value, String key) =>
    !value.containsKey(key) || value[key] is String;
