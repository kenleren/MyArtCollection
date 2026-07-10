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
  });

  final String requestId;
  final String payloadHash;
  final String body;
}

abstract interface class BrokerRetryStore {
  Future<void> save(FrozenBrokerRequest request);

  Future<FrozenBrokerRequest?> read(String requestId);

  Future<void> clear(String requestId);
}

class FileBrokerRetryStore implements BrokerRetryStore {
  const FileBrokerRetryStore._(this._directory);

  final Directory _directory;

  static Future<FileBrokerRetryStore> open() async {
    final root = await getApplicationSupportDirectory();
    return openAt(Directory(path.join(root.path, 'research-retry')));
  }

  static Future<FileBrokerRetryStore> openAt(Directory directory) async {
    await directory.create(recursive: true);
    return FileBrokerRetryStore._(directory);
  }

  @override
  Future<void> save(FrozenBrokerRequest request) async {
    final destination = _fileFor(request.requestId);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, String>{
        'request_id': request.requestId,
        'payload_hash': request.payloadHash,
        'body': request.body,
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
          decoded['request_id'] != requestId ||
          decoded['payload_hash'] is! String ||
          decoded['body'] is! String) {
        return null;
      }
      return FrozenBrokerRequest(
        requestId: requestId,
        payloadHash: decoded['payload_hash']! as String,
        body: decoded['body']! as String,
      );
    } on Object {
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

class BrokerClientFailure {
  const BrokerClientFailure({
    required this.code,
    required this.message,
    this.retryAfterSeconds,
  });

  final String code;
  final String message;
  final int? retryAfterSeconds;
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

  final Map<String, Object?>? response;
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

  Future<BrokerClientResult> submit(BrokerRequestPayload payload) async {
    final request = payload.toRequest();
    final frozen = FrozenBrokerRequest(
      requestId: payload.requestId,
      payloadHash: request['payload_hash']! as String,
      body: jsonEncode(<String, Object?>{'data': request}),
    );
    return _submitFrozen(frozen, saveBeforeSend: true);
  }

  Future<BrokerClientResult> retry(String requestId) async {
    final frozen = await retryStore.read(requestId);
    if (frozen == null) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'retry_not_available',
          message: 'No saved research request is available.',
        ),
      );
    }
    return _submitFrozen(frozen, saveBeforeSend: false);
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

  Future<BrokerClientResult> _submitFrozen(
    FrozenBrokerRequest frozen, {
    required bool saveBeforeSend,
  }) async {
    if (!featureFlags.isConfiguredBrokerEndpoint(endpoint)) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'endpoint_unavailable',
          message: 'Research is unavailable.',
        ),
      );
    }

    final flags = await featureFlags.loadAfterConsent();
    if (!flags.localResearchCapabilityEnabled || !flags.onlineResearchEnabled) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'research_disabled',
          message: 'Research is unavailable.',
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
    await retryStore.clear(frozen.requestId);
    final body = _jsonObject(transportResponse.body);
    if (transportResponse.statusCode == 200 &&
        body != null &&
        _isValidSuccessResponse(body, frozen.requestId)) {
      return BrokerClientResult.success(
        body,
        refreshedAfterUnauthorized: refreshedAfterUnauthorized,
      );
    }
    return BrokerClientResult.failure(
      _safeBrokerFailure(body),
      refreshedAfterUnauthorized: refreshedAfterUnauthorized,
    );
  }
}

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

BrokerClientFailure _safeBrokerFailure(Map<String, Object?>? body) {
  if (body == null || body['error_contract_version'] != 'broker-error-v1') {
    return const BrokerClientFailure(
      code: 'invalid_broker_response',
      message: 'Research is temporarily unavailable.',
    );
  }
  final error = body['error'];
  if (error is! Map<Object?, Object?> ||
      error['code'] is! String ||
      !_brokerErrorCodes.contains(error['code'])) {
    return const BrokerClientFailure(
      code: 'invalid_broker_response',
      message: 'Research is temporarily unavailable.',
    );
  }
  final retryAfter = error['retry_after_seconds'];
  return BrokerClientFailure(
    code: error['code']! as String,
    message: 'Research is temporarily unavailable.',
    retryAfterSeconds: retryAfter is int && retryAfter >= 5 && retryAfter <= 300
        ? retryAfter
        : null,
  );
}

bool _isValidSuccessResponse(Map<String, Object?> body, String requestId) {
  if (body['request_id'] != requestId ||
      body['status'] != 'completed' ||
      body['provider'] is! String ||
      body['model'] is! String ||
      body['reasoning_effort'] is! String ||
      body['completed_at'] is! String ||
      body['sources'] is! List ||
      body['candidate_attributions'] is! List ||
      body['comparable_value_signals'] is! List ||
      body['warnings'] is! List) {
    return false;
  }
  return DateTime.tryParse(body['completed_at']! as String) != null;
}

const _brokerErrorCodes = <String>{
  'method_not_allowed',
  'unsupported_media_type',
  'payload_invalid',
  'temporarily_unavailable',
  'unauthorized',
  'forbidden',
  'consent_required',
  'consent_stale',
  'not_entitled',
  'payload_too_large',
  'idempotency_conflict',
  'request_in_flight',
  'credits_exhausted',
  'request_expired',
  'request_outcome_unknown',
  'rate_limited',
  'upstream_refusal',
  'upstream_timeout',
  'upstream_failure',
  'upstream_invalid_output',
};
