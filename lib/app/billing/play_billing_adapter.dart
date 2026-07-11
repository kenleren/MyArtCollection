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
    this.plan,
    this.productId,
    this.leaseExpiresAt,
  });

  factory PlayBillingVerification.free(String requestId) =>
      PlayBillingVerification._(requestId: requestId, state: 'free');

  factory PlayBillingVerification.paid({
    required String requestId,
    required EntitlementPlan plan,
    required String productId,
    required String state,
    required DateTime leaseExpiresAt,
  }) => PlayBillingVerification._(
    requestId: requestId,
    state: state,
    plan: plan,
    productId: productId,
    leaseExpiresAt: leaseExpiresAt,
  );

  final String requestId;
  final String state;
  final EntitlementPlan? plan;
  final String? productId;
  final DateTime? leaseExpiresAt;

  bool get isPaid => plan != null && leaseExpiresAt != null;
}

abstract interface class PlayBillingVerifier {
  /// Called only after the billing disclosure has been accepted in the UI.
  Future<String?> ensureBillingIdentity();
  Future<bool> acceptDisclosure(String requestId);
  Future<PlayBillingVerification> verify({
    required String requestId,
    required String productId,
    required String purchaseToken,
  });
}

class FirebasePlayBillingVerifier implements PlayBillingVerifier {
  FirebasePlayBillingVerifier(
    this._runtime, {
    FirebaseFunctions? functions,
    DateTime Function()? now,
  }) : _functions = functions ?? FirebaseFunctions.instance,
       _now = now ?? DateTime.now;

  final FirebaseResearchRuntime _runtime;
  final FirebaseFunctions _functions;
  final DateTime Function() _now;

  @override
  Future<String?> ensureBillingIdentity() async {
    try {
      await _runtime.initializeFirebase();
      await _runtime.initializeAppCheck();
      await _runtime.signInAnonymously();
      return _runtime.currentUserId();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> acceptDisclosure(String requestId) async {
    try {
      final result = await _functions
          .httpsCallable('acceptPlayBillingDisclosure')
          .call(<String, Object>{
            'requestId': requestId,
            'disclosureVersion': _disclosureVersion,
            'purpose': _disclosurePurpose,
            'accepted': true,
          });
      final data = result.data;
      return data is Map &&
          data['version'] == _contractVersion &&
          data['requestId'] == requestId &&
          data['status'] == 'accepted';
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
    try {
      final result = await _functions
          .httpsCallable('verifyPlaySubscription')
          .call(<String, Object>{
            'requestId': requestId,
            'billingDisclosureVersion': _disclosureVersion,
            'productId': productId,
            'purchaseToken': purchaseToken,
          });
      return _parseVerification(result.data, requestId, _now());
    } catch (_) {
      return PlayBillingVerification.free(requestId);
    }
  }
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
    return PlayBillingVerification.free(requestId);
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
  if (verified == null ||
      playExpiry == null ||
      leaseExpiry == null ||
      !leaseExpiry.isAfter(now.toUtc()) ||
      leaseExpiry.isAfter(playExpiry) ||
      leaseExpiry.isAfter(verified.add(_maxLease))) {
    return PlayBillingVerification.free(requestId);
  }
  return PlayBillingVerification.paid(
    requestId: requestId,
    plan: plan,
    productId: productId,
    state: state,
    leaseExpiresAt: leaseExpiry,
  );
}

/// Fail-closed, memory-only coordinator for the server-verified Play lease.
class PlayBillingEntitlementService implements EntitlementService {
  PlayBillingEntitlementService(
    this._store,
    this._verifier, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _purchaseSubscription = _store.purchaseStream.listen(_onPurchase);
  }

  final PlayBillingStore _store;
  final PlayBillingVerifier _verifier;
  final DateTime Function() _now;
  final Set<String> _inFlightTokens = <String>{};
  late final StreamSubscription<PlayPurchase> _purchaseSubscription;

  _Lease? _lease;
  int _generation = 0;
  String? _currentRequestId;
  String? _currentUid;
  bool _disposed = false;
  bool _disclosureAccepted = false;

  @override
  Future<EntitlementState> currentState() async {
    if (_disposed) return _free(EntitlementBillingStatus.unavailable);
    final available = await _storeAvailable();
    final lease = _lease;
    if (!available) {
      _transitionFree();
      return _free(EntitlementBillingStatus.unavailable);
    }
    if (lease != null && lease.expiresAt.isAfter(_now().toUtc())) {
      return EntitlementState(
        plan: lease.plan,
        billingStatus: EntitlementBillingStatus.available,
      );
    }
    if (lease != null) {
      _transitionFree();
    }
    return _free(EntitlementBillingStatus.available);
  }

  Future<List<PlayProduct>> products() async {
    if (!await _storeAvailable()) return const <PlayProduct>[];
    final result = await _store.queryProducts(_paidProductIds);
    if (result.unavailable) return const <PlayProduct>[];
    return result.products
        .where((product) => _paidProductIds.contains(product.id))
        .toList(growable: false);
  }

  /// The caller invokes this only after displaying the billing disclosure.
  Future<bool> acceptBillingDisclosure() async {
    final uid = await _verifier.ensureBillingIdentity();
    if (uid == null) return false;
    _observeUid(uid);
    _disclosureAccepted = await _verifier.acceptDisclosure(_newRequestId());
    return _disclosureAccepted;
  }

  Future<bool> purchase(EntitlementPlan plan) async {
    final productId = plan.playProductId;
    if (productId == null || !_disclosureAccepted || !await _storeAvailable()) {
      return false;
    }
    final uid = await _verifier.ensureBillingIdentity();
    if (uid == null) return false;
    _observeUid(uid);
    final products = await _store.queryProducts(<String>{productId});
    final product = products.products
        .where((item) => item.id == productId)
        .firstOrNull;
    if (products.unavailable || product == null) return false;
    _beginOperation(uid);
    return _store.buySubscription(product, _obfuscatedAccountId(uid));
  }

  Future<void> restore() async {
    if (!_disclosureAccepted || !await _storeAvailable()) {
      _transitionFree();
      return;
    }
    final uid = await _verifier.ensureBillingIdentity();
    if (uid == null) {
      _transitionFree();
      return;
    }
    _observeUid(uid);
    _beginOperation(uid);
    await _store.restorePurchases();
  }

  Future<void> refreshForForeground() => _refresh();
  Future<void> refreshForGatedAction() => _refresh();

  Future<void> _refresh() async {
    final uid = _currentUid;
    if (!_disclosureAccepted || !await _storeAvailable() || uid == null) {
      _transitionFree();
      return;
    }
    _beginOperation(uid);
    await _store.restorePurchases();
  }

  void handleAccountChange() => _transitionFree(clearPurchase: true);

  Future<void> _onPurchase(PlayPurchase purchase) async {
    if (_disposed) return;
    final uid = _currentUid;
    switch (purchase.state) {
      case PlayPurchaseState.pending:
        _transitionFree();
      case PlayPurchaseState.canceled:
      case PlayPurchaseState.error:
        _transitionFree(clearPurchase: true);
      case PlayPurchaseState.purchased:
      case PlayPurchaseState.restored:
        if (uid == null ||
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
    final requestId = _beginOperation(uid);
    final generation = _generation;
    PlayBillingVerification result;
    try {
      result = await _verifier.verify(
        requestId: requestId,
        productId: purchase.productId,
        purchaseToken: purchase.purchaseToken,
      );
    } catch (_) {
      if (generation == _generation && requestId == _currentRequestId) {
        _transitionFree();
      }
      return;
    }
    if (_disposed ||
        generation != _generation ||
        requestId != _currentRequestId ||
        uid != _currentUid) {
      return;
    }
    if (!result.isPaid ||
        result.requestId != requestId ||
        result.productId != purchase.productId) {
      _transitionFree();
      return;
    }
    _lease = _Lease(result.plan!, result.leaseExpiresAt!);
  }

  String _beginOperation(String uid) {
    _generation++;
    _lease = null;
    _currentUid = uid;
    return _currentRequestId = _newRequestId();
  }

  void _observeUid(String uid) {
    if (_currentUid != null && _currentUid != uid) {
      _transitionFree(clearPurchase: true);
    }
    _currentUid = uid;
  }

  void _transitionFree({bool clearPurchase = false}) {
    _generation++;
    _lease = null;
    _currentRequestId = null;
    if (clearPurchase) {
      _currentUid = null;
      _disclosureAccepted = false;
    }
  }

  Future<bool> _storeAvailable() async {
    try {
      return await _store.isAvailable();
    } catch (_) {
      return false;
    }
  }

  EntitlementState _free(EntitlementBillingStatus status) =>
      EntitlementState(plan: EntitlementPlans.free, billingStatus: status);

  Future<void> dispose() async {
    _disposed = true;
    _transitionFree(clearPurchase: true);
    await _purchaseSubscription.cancel();
  }
}

class _Lease {
  const _Lease(this.plan, this.expiresAt);
  final EntitlementPlan plan;
  final DateTime expiresAt;
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
