import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import '../research/firebase_research_runtime.dart';
import 'entitlement_plan.dart';

const _contractVersion = 'play-billing-v1';
const _disclosureVersion = 'billing-verification-disclosure-v1';
const _disclosurePurpose = 'play_subscription_verification';
const _maxLease = Duration(minutes: 15);
// A device can start with a stale wall clock. The lease never uses wall time,
// so this only rejects implausibly distant server timestamps.
const _maxVerifiedAtFutureSkew = Duration(hours: 24);
const _functionsRegion = 'us-central1';
const _callableTimeout = Duration(seconds: 60);
const _maxUnresolvedRecoveryAttempts = 2;

enum PlayPurchaseState { pending, purchased, restored, canceled, error }

class PlayProduct {
  const PlayProduct({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    this.platformProduct,
  });

  final String id;
  final String title;
  final String description;
  final String price;
  final Object? platformProduct;
}

class PlayProductQuery {
  const PlayProductQuery({required this.products, this.unavailable = false});

  final List<PlayProduct> products;
  final bool unavailable;
}

class PlayPurchase {
  const PlayPurchase({
    required this.productId,
    required this.purchaseToken,
    required this.state,
  });

  final String productId;
  final String purchaseToken;
  final PlayPurchaseState state;
}

/// Small facade over Play Billing so tests never need a platform channel.
abstract interface class PlayBillingStore {
  Future<bool> isAvailable();
  Future<PlayProductQuery> queryProducts(Set<String> productIds);
  Stream<PlayPurchase> get purchaseStream;
  Future<bool> buySubscription(PlayProduct product, String obfuscatedAccountId);
  Future<void> restorePurchases();
}

/// The narrow UI-facing command surface. It intentionally exposes no payment
/// tokens, account IDs, verifier responses, or expiry details.
abstract interface class BillingManagementService
    implements EntitlementService {
  /// Sanitized state changes for mounted billing UI. This never carries
  /// purchase, identity, verifier, or expiry details.
  Stream<EntitlementState> get stateChanges;
  Future<List<PlayProduct>> products();
  Future<bool> acceptBillingDisclosure();
  Future<bool> purchase(EntitlementPlan plan);
  Future<void> restore();
  Future<void> refreshForForeground();
  void handleAccountChange();
}

class InAppPurchasePlayBillingStore implements PlayBillingStore {
  InAppPurchasePlayBillingStore({InAppPurchase? inAppPurchase})
    : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance;

  final InAppPurchase _inAppPurchase;

  @override
  Future<bool> isAvailable() => _inAppPurchase.isAvailable();

  @override
  Stream<PlayPurchase> get purchaseStream => _inAppPurchase.purchaseStream
      .expand((updates) => updates.map(_toPurchase));

  @override
  Future<PlayProductQuery> queryProducts(Set<String> productIds) async {
    final result = await _inAppPurchase.queryProductDetails(productIds);
    if (result.error != null) {
      return const PlayProductQuery(
        products: <PlayProduct>[],
        unavailable: true,
      );
    }
    return PlayProductQuery(
      products: result.productDetails
          .map(
            (product) => PlayProduct(
              id: product.id,
              title: product.title,
              description: product.description,
              price: product.price,
              platformProduct: product,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<bool> buySubscription(
    PlayProduct product,
    String obfuscatedAccountId,
  ) {
    final details = product.platformProduct;
    if (details is! ProductDetails) {
      return Future<bool>.value(false);
    }
    // applicationUserName is passed to Play as the obfuscated account ID.
    final parameter = GooglePlayPurchaseParam(
      productDetails: details,
      applicationUserName: obfuscatedAccountId,
    );
    return _inAppPurchase.buyNonConsumable(purchaseParam: parameter);
  }

  @override
  Future<void> restorePurchases() => _inAppPurchase.restorePurchases();

  PlayPurchase _toPurchase(PurchaseDetails details) => PlayPurchase(
    productId: details.productID,
    purchaseToken: details.verificationData.serverVerificationData,
    state: switch (details.status) {
      PurchaseStatus.pending => PlayPurchaseState.pending,
      PurchaseStatus.purchased => PlayPurchaseState.purchased,
      PurchaseStatus.restored => PlayPurchaseState.restored,
      PurchaseStatus.canceled => PlayPurchaseState.canceled,
      PurchaseStatus.error => PlayPurchaseState.error,
    },
  );
}

class PlayBillingVerification {
  const PlayBillingVerification._({
    required this.requestId,
    required this.state,
    this.presentation = EntitlementPresentation.idle,
    this.plan,
    this.productId,
    this.leaseDuration,
  });

  factory PlayBillingVerification.free(
    String requestId, {
    EntitlementPresentation presentation = EntitlementPresentation.idle,
  }) => PlayBillingVerification._(
    requestId: requestId,
    state: 'free',
    presentation: presentation,
  );

  factory PlayBillingVerification.paid({
    required String requestId,
    required EntitlementPlan plan,
    required String productId,
    required String state,
    required Duration leaseDuration,
  }) => PlayBillingVerification._(
    requestId: requestId,
    state: state,
    plan: plan,
    productId: productId,
    leaseDuration: leaseDuration,
  );

  final String requestId;
  final String state;
  final EntitlementPlan? plan;
  final String? productId;
  final Duration? leaseDuration;
  final EntitlementPresentation presentation;

  bool get isPaid => plan != null && leaseDuration != null;
}

abstract interface class PlayBillingVerifier {
  /// Called only after the billing disclosure has been accepted in the UI.
  Future<String?> ensureBillingIdentity();
  String? currentBillingUserId();
  Future<bool> acceptDisclosure(String requestId);
  Future<PlayBillingVerification> verify({
    required String requestId,
    required String productId,
    required String purchaseToken,
  });
}

/// Optional sanitized identity-change signal. It carries no account details
/// and lets the entitlement coordinator clear its memory-only lease promptly.
abstract interface class PlayBillingIdentityObserver {
  Stream<void> get billingIdentityChanges;
}

/// A narrow callable boundary keeps Functions resolution out of startup and
/// lets tests inspect every callable contract without a Firebase app.
abstract interface class PlayBillingCallable {
  Future<Object?> call(Map<String, Object> data);
}

class PlayBillingCallableOptions {
  const PlayBillingCallableOptions({
    required this.region,
    required this.timeout,
    required this.limitedUseAppCheckToken,
  });

  final String region;
  final Duration timeout;
  final bool limitedUseAppCheckToken;
}

abstract interface class PlayBillingCallableFactory {
  PlayBillingCallable create(
    String name, {
    required PlayBillingCallableOptions options,
  });
}

class FirebasePlayBillingCallableFactory implements PlayBillingCallableFactory {
  const FirebasePlayBillingCallableFactory();

  @override
  PlayBillingCallable create(
    String name, {
    required PlayBillingCallableOptions options,
  }) {
    // This is called only after the consent-gated runtime initialized Firebase.
    final callable = FirebaseFunctions.instanceFor(region: options.region)
        .httpsCallable(
          name,
          options: HttpsCallableOptions(
            timeout: options.timeout,
            limitedUseAppCheckToken: options.limitedUseAppCheckToken,
          ),
        );
    return _FirebasePlayBillingCallable(callable);
  }
}

class _FirebasePlayBillingCallable implements PlayBillingCallable {
  const _FirebasePlayBillingCallable(this._callable);

  final HttpsCallable _callable;

  @override
  Future<Object?> call(Map<String, Object> data) async =>
      (await _callable.call(data)).data;
}

class FirebasePlayBillingVerifier
    implements PlayBillingVerifier, PlayBillingIdentityObserver {
  FirebasePlayBillingVerifier(
    this._runtime, {
    this._callableFactory = const FirebasePlayBillingCallableFactory(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final FirebaseResearchRuntime _runtime;
  final PlayBillingCallableFactory _callableFactory;
  final DateTime Function() _now;
  final StreamController<void> _billingIdentityChanges =
      StreamController<void>.broadcast();
  bool _identityInitialized = false;
  StreamSubscription<String?>? _identitySubscription;
  String? _observedUserId;

  @override
  Stream<void> get billingIdentityChanges => _billingIdentityChanges.stream;

  @override
  Future<String?> ensureBillingIdentity() async {
    try {
      await _runtime.initializeFirebase();
      await _runtime.initializeAppCheck();
      await _runtime.signInAnonymously();
      final uid = _runtime.currentUserId();
      _identityInitialized = uid != null;
      _observeIdentityChanges(uid);
      return uid;
    } catch (_) {
      _identityInitialized = false;
      return null;
    }
  }

  void _observeIdentityChanges(String? initialUid) {
    _observedUserId = initialUid;
    if (_runtime is! FirebaseResearchIdentityObserver ||
        _identitySubscription != null) {
      return;
    }
    final observer = _runtime as FirebaseResearchIdentityObserver;
    _identitySubscription = observer.userIdChanges.listen((uid) {
      if (uid == _observedUserId) return;
      _observedUserId = uid;
      if (!_billingIdentityChanges.isClosed) {
        _billingIdentityChanges.add(null);
      }
    });
  }

  @override
  String? currentBillingUserId() =>
      _identityInitialized ? _runtime.currentUserId() : null;

  @override
  Future<bool> acceptDisclosure(String requestId) async {
    if (!_identityInitialized) return false;
    try {
      final result = await _callable('acceptPlayBillingDisclosure')
          .call(<String, Object>{
            'requestId': requestId,
            'disclosureVersion': _disclosureVersion,
            'purpose': _disclosurePurpose,
            'accepted': true,
          });
      return result is Map &&
          result['version'] == _contractVersion &&
          result['requestId'] == requestId &&
          result['status'] == 'accepted';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PlayBillingVerification> verify({
    required String requestId,
    required String productId,
    required String purchaseToken,
  }) async {
    if (!_identityInitialized) return PlayBillingVerification.free(requestId);
    try {
      final result = await _callable('verifyPlaySubscription')
          .call(<String, Object>{
            'requestId': requestId,
            'billingDisclosureVersion': _disclosureVersion,
            'productId': productId,
            'purchaseToken': purchaseToken,
          });
      return _parseVerification(result, requestId, _now());
    } catch (_) {
      return PlayBillingVerification.free(requestId);
    }
  }

  PlayBillingCallable _callable(String name) => _callableFactory.create(
    name,
    options: const PlayBillingCallableOptions(
      region: _functionsRegion,
      timeout: _callableTimeout,
      limitedUseAppCheckToken: true,
    ),
  );
}

PlayBillingVerification _parseVerification(
  Object? raw,
  String requestId,
  DateTime now,
) {
  if (raw is! Map ||
      raw['version'] != _contractVersion ||
      raw['requestId'] != requestId) {
    return PlayBillingVerification.free(requestId);
  }
  if (raw['state'] == 'free') {
    return PlayBillingVerification.free(
      requestId,
      presentation: _presentationForFreeReason(raw['reason']),
    );
  }
  final planId = raw['planId'];
  final productId = raw['productId'];
  final state = raw['state'];
  final verifiedAt = raw['verifiedAt'];
  final playExpiresAt = raw['playExpiresAt'];
  final leaseExpiresAt = raw['leaseExpiresAt'];
  final plan = _planForId(planId);
  if (plan == null ||
      productId != plan.playProductId ||
      state is! String ||
      !const {'active', 'grace', 'canceled'}.contains(state) ||
      verifiedAt is! String ||
      playExpiresAt is! String ||
      leaseExpiresAt is! String) {
    return PlayBillingVerification.free(requestId);
  }
  final verified = DateTime.tryParse(verifiedAt)?.toUtc();
  final playExpiry = DateTime.tryParse(playExpiresAt)?.toUtc();
  final leaseExpiry = DateTime.tryParse(leaseExpiresAt)?.toUtc();
  final receivedAt = now.toUtc();
  if (verified == null ||
      playExpiry == null ||
      leaseExpiry == null ||
      verified.isAfter(receivedAt.add(_maxVerifiedAtFutureSkew)) ||
      !leaseExpiry.isAfter(verified) ||
      leaseExpiry.isAfter(playExpiry) ||
      leaseExpiry.difference(verified) > _maxLease) {
    return PlayBillingVerification.free(requestId);
  }
  return PlayBillingVerification.paid(
    requestId: requestId,
    plan: plan,
    productId: productId,
    state: state,
    leaseDuration: leaseExpiry.difference(verified),
  );
}

/// Separates receipt-wall time from the process-monotonic lease timer.
abstract interface class PlayBillingClock {
  DateTime wallNow();
  Duration elapsed();
}

class SystemPlayBillingClock implements PlayBillingClock {
  SystemPlayBillingClock() : _started = Stopwatch()..start();

  final Stopwatch _started;

  @override
  Duration elapsed() => _started.elapsed;

  @override
  DateTime wallNow() => DateTime.now();
}

/// Fail-closed, memory-only coordinator for the server-verified Play lease.
class PlayBillingEntitlementService implements BillingManagementService {
  PlayBillingEntitlementService(
    this._store,
    this._verifier, {
    PlayBillingClock? clock,
  }) : _clock = clock ?? SystemPlayBillingClock() {
    _purchaseSubscription = _store.purchaseStream.listen(_onPurchase);
    if (_verifier case PlayBillingIdentityObserver observer) {
      _identitySubscription = observer.billingIdentityChanges.listen((_) {
        handleAccountChange();
      });
    }
  }

  final PlayBillingStore _store;
  final PlayBillingVerifier _verifier;
  final PlayBillingClock _clock;
  final Set<String> _inFlightTokens = <String>{};
  final StreamController<EntitlementState> _stateChanges =
      StreamController<EntitlementState>.broadcast();
  late final StreamSubscription<PlayPurchase> _purchaseSubscription;
  StreamSubscription<void>? _identitySubscription;

  _Lease? _lease;
  Timer? _leaseExpiryTimer;
  int _generation = 0;
  String? _currentRequestId;
  String? _currentUid;
  bool _disposed = false;
  bool _disclosureAccepted = false;
  EntitlementPresentation _presentation = EntitlementPresentation.idle;
  EntitlementPresentation? _recoveryFallbackPresentation;
  int _unresolvedRecoveryAttempts = 0;
  bool _recovering = false;

  @override
  Stream<EntitlementState> get stateChanges => _stateChanges.stream;

  @override
  Future<EntitlementState> currentState() async {
    if (_disposed) return _free(EntitlementBillingStatus.unavailable);
    final fence = _captureFence();
    if (!_isFenceCurrent(fence, requireIdentity: fence.uid != null)) {
      return _free(EntitlementBillingStatus.available);
    }
    final available = await _storeAvailable();
    if (!_isFenceCurrent(fence, requireIdentity: fence.uid != null)) {
      return _free(
        available
            ? EntitlementBillingStatus.available
            : EntitlementBillingStatus.unavailable,
      );
    }
    final lease = _lease;
    if (!available) {
      _transitionFree(status: EntitlementBillingStatus.unavailable);
      return _free(EntitlementBillingStatus.unavailable);
    }
    if (lease != null && _clock.elapsed() < lease.expiresAtElapsed) {
      return _paid(lease);
    }
    if (lease != null) {
      _transitionFree();
    }
    return _free(EntitlementBillingStatus.available);
  }

  @override
  Future<List<PlayProduct>> products() async {
    final fence = _captureFence();
    if (!await _storeAvailable() ||
        !_isFenceCurrent(fence, requireIdentity: fence.uid != null)) {
      return const <PlayProduct>[];
    }
    final result = await _queryProducts(_paidProductIds);
    if (result.unavailable ||
        !_isFenceCurrent(fence, requireIdentity: fence.uid != null)) {
      return const <PlayProduct>[];
    }
    return result.products
        .where((product) => _paidProductIds.contains(product.id))
        .toList(growable: false);
  }

  /// The caller invokes this only after displaying the billing disclosure.
  @override
  Future<bool> acceptBillingDisclosure() async {
    final entryFence = _captureFence();
    final uid = await _ensureBillingIdentity();
    if (!_isFenceCurrent(entryFence) || uid == null) return false;
    _observeUid(uid);
    final fence = _beginOperation(uid);
    final accepted = await _verifier.acceptDisclosure(fence.requestId!);
    if (!_isFenceCurrent(fence, requireIdentity: true)) return false;
    if (!accepted) {
      _transitionFree(clearPurchase: true);
      return false;
    }
    _disclosureAccepted = true;
    return true;
  }

  @override
  Future<bool> purchase(EntitlementPlan plan) async {
    final productId = plan.playProductId;
    if (productId == null || !_disclosureAccepted) {
      return false;
    }
    final entryFence = _beginPreflight(
      presentation: EntitlementPresentation.inFlight,
    );
    if (!await _storeAvailable() ||
        !_isFenceCurrent(entryFence, requireIdentity: true)) {
      _failPreflight(entryFence);
      return false;
    }
    final uid = await _ensureBillingIdentity();
    if (!_isFenceCurrent(entryFence, requireIdentity: true) || uid == null) {
      _failPreflight(entryFence);
      return false;
    }
    _observeUid(uid);
    if (!_disclosureAccepted || _currentUid != uid) return false;
    final products = await _queryProducts(<String>{productId});
    if (!_isFenceCurrent(entryFence, requireIdentity: true)) {
      _failPreflight(entryFence);
      return false;
    }
    final product = products.products
        .where((item) => item.id == productId)
        .firstOrNull;
    if (products.unavailable || product == null) {
      _failPreflight(entryFence);
      return false;
    }
    final purchaseFence = _beginOperation(uid);
    bool started;
    try {
      started = await _store.buySubscription(
        product,
        _obfuscatedAccountId(uid),
      );
    } catch (_) {
      if (_isFenceCurrent(purchaseFence, requireIdentity: true)) {
        _transitionFree();
      }
      return false;
    }
    if (started && _isFenceCurrent(purchaseFence, requireIdentity: true)) {
      _presentation = EntitlementPresentation.inFlight;
      _publish();
      return true;
    }
    return false;
  }

  @override
  Future<void> restore() async {
    await _recover(EntitlementPresentation.restoring);
  }

  @override
  Future<void> refreshForForeground() => _refresh();
  Future<void> refreshForGatedAction() => _refresh();

  Future<void> _refresh() => _recover(EntitlementPresentation.refreshing);

  Future<void> _recover(EntitlementPresentation recoveryPresentation) async {
    final fallbackPresentation = _presentation;
    final retainUnresolved = _isUnresolved(fallbackPresentation);
    if (_recovering ||
        (retainUnresolved &&
            _unresolvedRecoveryAttempts >= _maxUnresolvedRecoveryAttempts)) {
      return;
    }
    if (!_disclosureAccepted || _currentUid == null) {
      _transitionFree();
      return;
    }

    _beginRecovery(
      recoveryPresentation,
      fallbackPresentation,
      retainUnresolved,
    );
    final fence = _captureFence();
    if (!_isFenceCurrent(fence, requireIdentity: true)) return;
    final available = await _storeAvailable();
    if (!available || !_isFenceCurrent(fence, requireIdentity: true)) {
      _completeRecovery(fence, unavailable: !available);
      return;
    }
    try {
      await _store.restorePurchases();
    } catch (_) {
      _completeRecovery(fence);
      return;
    }
    _completeRecovery(fence);
  }

  void _beginRecovery(
    EntitlementPresentation recoveryPresentation,
    EntitlementPresentation fallbackPresentation,
    bool retainUnresolved,
  ) {
    _recovering = true;
    _recoveryFallbackPresentation = retainUnresolved
        ? fallbackPresentation
        : null;
    if (retainUnresolved) {
      _unresolvedRecoveryAttempts++;
    } else {
      _generation++;
      _lease = null;
      _leaseExpiryTimer?.cancel();
      _currentRequestId = null;
    }
    _presentation = recoveryPresentation;
    _publish();
  }

  void _completeRecovery(_OperationFence fence, {bool unavailable = false}) {
    if (!_isFenceCurrent(fence, requireIdentity: true)) return;
    _recovering = false;
    final fallbackPresentation = _recoveryFallbackPresentation;
    _recoveryFallbackPresentation = null;
    if (fallbackPresentation != null) {
      _presentation = fallbackPresentation;
      _publish();
      return;
    }
    _transitionFree(
      status: unavailable
          ? EntitlementBillingStatus.unavailable
          : EntitlementBillingStatus.available,
    );
  }

  @override
  void handleAccountChange() => _transitionFree(clearPurchase: true);

  Future<void> _onPurchase(PlayPurchase purchase) async {
    if (_disposed) return;
    final uid = _currentUid;
    final eventFence = _captureFence();
    _recovering = false;
    _recoveryFallbackPresentation = null;
    switch (purchase.state) {
      case PlayPurchaseState.pending:
        _transitionFree(presentation: EntitlementPresentation.playPending);
        return;
      case PlayPurchaseState.canceled:
      case PlayPurchaseState.error:
        _transitionFree(clearPurchase: true);
      case PlayPurchaseState.purchased:
      case PlayPurchaseState.restored:
        if (uid == null ||
            !_isFenceCurrent(eventFence, requireIdentity: true) ||
            purchase.purchaseToken.isEmpty ||
            !_paidProductIds.contains(purchase.productId)) {
          _transitionFree(clearPurchase: true);
          return;
        }
        if (!_inFlightTokens.add(purchase.purchaseToken)) return;
        try {
          await _verifyPurchase(purchase, uid);
        } finally {
          _inFlightTokens.remove(purchase.purchaseToken);
        }
    }
  }

  Future<void> _verifyPurchase(PlayPurchase purchase, String uid) async {
    final fence = _beginOperation(uid);
    _presentation = EntitlementPresentation.verificationPending;
    _publish();
    final verificationStartedAt = _clock.elapsed();
    PlayBillingVerification result;
    try {
      result = await _verifier.verify(
        requestId: fence.requestId!,
        productId: purchase.productId,
        purchaseToken: purchase.purchaseToken,
      );
    } catch (_) {
      if (_isFenceCurrent(fence, requireIdentity: true)) {
        _transitionFree();
      }
      return;
    }
    if (!_isFenceCurrent(fence, requireIdentity: true)) {
      return;
    }
    if (!result.isPaid ||
        result.requestId != fence.requestId ||
        result.productId != purchase.productId) {
      _transitionFree(presentation: result.presentation);
      return;
    }
    final duration = result.leaseDuration!;
    if (duration <= Duration.zero || duration > _maxLease) {
      _transitionFree();
      return;
    }
    final expiresAtElapsed = verificationStartedAt + duration;
    if (_clock.elapsed() >= expiresAtElapsed) {
      _transitionFree();
      return;
    }
    _lease = _Lease(
      result.plan!,
      expiresAtElapsed,
      result.state == 'grace'
          ? EntitlementLifecycle.grace
          : result.state == 'canceled'
          ? EntitlementLifecycle.canceledThroughExpiry
          : EntitlementLifecycle.active,
    );
    _presentation = EntitlementPresentation.idle;
    _scheduleLeaseExpiry(_lease!);
    _publish();
  }

  _OperationFence _beginPreflight({
    EntitlementPresentation presentation = EntitlementPresentation.idle,
  }) {
    _generation++;
    _lease = null;
    _currentRequestId = null;
    _leaseExpiryTimer?.cancel();
    _resetRecoveryAttempts();
    _presentation = presentation;
    _publish();
    return _captureFence();
  }

  void _failPreflight(_OperationFence fence) {
    if (_isFenceCurrent(fence)) {
      _transitionFree();
    }
  }

  _OperationFence _beginOperation(String uid) {
    _generation++;
    _lease = null;
    _currentUid = uid;
    _currentRequestId = _newRequestId();
    _resetRecoveryAttempts();
    return _captureFence();
  }

  _OperationFence _captureFence() => _OperationFence(
    generation: _generation,
    uid: _currentUid,
    requestId: _currentRequestId,
  );

  bool _isFenceCurrent(_OperationFence fence, {bool requireIdentity = false}) {
    if (_disposed ||
        fence.generation != _generation ||
        fence.uid != _currentUid ||
        fence.requestId != _currentRequestId) {
      return false;
    }
    if (!requireIdentity || fence.uid == null) return true;
    String? liveUid;
    try {
      liveUid = _verifier.currentBillingUserId();
    } catch (_) {
      _transitionFree(clearPurchase: true);
      return false;
    }
    if (liveUid != fence.uid) {
      _transitionFree(clearPurchase: true);
      return false;
    }
    return true;
  }

  void _observeUid(String uid) {
    if (_currentUid != null && _currentUid != uid) {
      _transitionFree(clearPurchase: true);
    }
    _currentUid = uid;
  }

  void _transitionFree({
    bool clearPurchase = false,
    EntitlementBillingStatus status = EntitlementBillingStatus.available,
    EntitlementPresentation presentation = EntitlementPresentation.idle,
  }) {
    _generation++;
    _lease = null;
    _leaseExpiryTimer?.cancel();
    _currentRequestId = null;
    _presentation = presentation;
    _resetRecoveryAttempts();
    if (clearPurchase) {
      _currentUid = null;
      _disclosureAccepted = false;
    }
    _publish(status: status);
  }

  bool _isUnresolved(EntitlementPresentation presentation) =>
      presentation == EntitlementPresentation.verificationPending ||
      presentation == EntitlementPresentation.inFlight ||
      presentation == EntitlementPresentation.playPending ||
      presentation == EntitlementPresentation.delayedVerification ||
      presentation == EntitlementPresentation.acknowledgementRecovery;

  void _resetRecoveryAttempts() {
    _recovering = false;
    _recoveryFallbackPresentation = null;
    _unresolvedRecoveryAttempts = 0;
  }

  Future<bool> _storeAvailable() async {
    try {
      return await _store.isAvailable();
    } catch (_) {
      return false;
    }
  }

  Future<String?> _ensureBillingIdentity() async {
    try {
      return await _verifier.ensureBillingIdentity();
    } catch (_) {
      return null;
    }
  }

  Future<PlayProductQuery> _queryProducts(Set<String> productIds) async {
    try {
      return await _store.queryProducts(productIds);
    } catch (_) {
      return const PlayProductQuery(
        products: <PlayProduct>[],
        unavailable: true,
      );
    }
  }

  EntitlementState _free(EntitlementBillingStatus status) => EntitlementState(
    plan: EntitlementPlans.free,
    billingStatus: status,
    lifecycle: EntitlementLifecycle.free,
    presentation: _presentation,
  );

  EntitlementState _paid(_Lease lease) => EntitlementState(
    plan: lease.plan,
    billingStatus: EntitlementBillingStatus.available,
    lifecycle: lease.lifecycle,
  );

  void _publish({
    EntitlementBillingStatus status = EntitlementBillingStatus.available,
  }) {
    if (_disposed || _stateChanges.isClosed) return;
    final lease = _lease;
    _stateChanges.add(
      lease != null && _clock.elapsed() < lease.expiresAtElapsed
          ? _paid(lease)
          : _free(status),
    );
  }

  void _scheduleLeaseExpiry(_Lease lease) {
    _leaseExpiryTimer?.cancel();
    final remaining = lease.expiresAtElapsed - _clock.elapsed();
    if (remaining <= Duration.zero) {
      _transitionFree();
      return;
    }
    _leaseExpiryTimer = Timer(remaining, () {
      if (identical(_lease, lease) &&
          _clock.elapsed() >= lease.expiresAtElapsed) {
        _transitionFree();
      }
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _transitionFree(clearPurchase: true);
    await _identitySubscription?.cancel();
    await _purchaseSubscription.cancel();
    await _stateChanges.close();
  }
}

class _Lease {
  const _Lease(this.plan, this.expiresAtElapsed, this.lifecycle);
  final EntitlementPlan plan;
  final Duration expiresAtElapsed;
  final EntitlementLifecycle lifecycle;
}

class _OperationFence {
  const _OperationFence({
    required this.generation,
    required this.uid,
    required this.requestId,
  });

  final int generation;
  final String? uid;
  final String? requestId;
}

final Set<String> _paidProductIds = EntitlementPlans.all
    .map((plan) => plan.playProductId)
    .whereType<String>()
    .toSet();

EntitlementPlan? _planForId(Object? id) {
  for (final plan in EntitlementPlans.all) {
    if (plan.id == id && plan.playProductId != null) return plan;
  }
  return null;
}

EntitlementPresentation _presentationForFreeReason(Object? reason) =>
    switch (reason) {
      'verification_pending' => EntitlementPresentation.verificationPending,
      'in_flight' => EntitlementPresentation.inFlight,
      'delayed_verification' => EntitlementPresentation.delayedVerification,
      'acknowledgement_recovery' =>
        EntitlementPresentation.acknowledgementRecovery,
      _ => EntitlementPresentation.idle,
    };

String _obfuscatedAccountId(String uid) => base64Url
    .encode(
      sha256.convert(utf8.encode('archivale-play-account-v1\n$uid')).bytes,
    )
    .replaceAll('=', '');

String _newRequestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
