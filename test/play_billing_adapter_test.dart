import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/billing/entitlement_plan.dart';
import 'package:my_art_collection/app/billing/play_billing_adapter.dart';

void main() {
  late FakeStore store;
  late FakeVerifier verifier;
  late DateTime now;
  late PlayBillingEntitlementService service;

  setUp(() {
    now = DateTime.utc(2026, 7, 11, 12);
    store = FakeStore();
    verifier = FakeVerifier(now: () => now);
    service = PlayBillingEntitlementService(store, verifier, now: () => now);
  });

  tearDown(() => service.dispose());

  Future<void> preparePurchase() async {
    store.products = <PlayProduct>[product(EntitlementPlans.starter)];
    expect(await service.acceptBillingDisclosure(), isTrue);
  }

  test(
    'product lookup returns only fixed Play products and unavailable fails closed',
    () async {
      store.products = <PlayProduct>[
        product(EntitlementPlans.starter),
        const PlayProduct(
          id: 'untrusted',
          title: '',
          description: '',
          price: '',
        ),
      ];
      expect((await service.products()).map((item) => item.id), <String>[
        EntitlementPlans.starter.playProductId!,
      ]);
      store.unavailable = true;
      expect(await service.products(), isEmpty);
    },
  );

  test(
    'purchase uses an obfuscated account ID only after billing identity bootstrap',
    () async {
      store.products = <PlayProduct>[product(EntitlementPlans.starter)];
      expect(await service.acceptBillingDisclosure(), isTrue);
      expect(await service.purchase(EntitlementPlans.starter), isTrue);
      expect(store.buyAccountId, hasLength(43));
      expect(store.buyAccountId, isNot('uid-a'));
      expect(verifier.accepts, hasLength(1));
    },
  );

  test(
    'purchase and restore do not start before disclosure acceptance',
    () async {
      store.products = <PlayProduct>[product(EntitlementPlans.starter)];
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      await service.restore();
      expect(store.restoreCalls, 0);
    },
  );

  test(
    'duplicate purchase stream events coalesce and never grant before verification',
    () async {
      await preparePurchase();
      final pending = Completer<PlayBillingVerification>();
      verifier.next = (_) => pending.future;
      store.emit(purchase(EntitlementPlans.starter));
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.free);
      expect(verifier.requests, hasLength(1));
      pending.complete(
        verifier.paidFor(EntitlementPlans.starter, verifier.requests.single),
      );
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.starter);
    },
  );

  test(
    'pending, canceled, and error purchase events leave the plan free',
    () async {
      await preparePurchase();
      for (final state in <PlayPurchaseState>[
        PlayPurchaseState.pending,
        PlayPurchaseState.canceled,
        PlayPurchaseState.error,
      ]) {
        store.emit(purchase(EntitlementPlans.starter, state: state));
        await tick();
        expect((await service.currentState()).plan, EntitlementPlans.free);
      }
      expect(verifier.requests, isEmpty);
    },
  );

  test('only a server-paid response can install a paid lease', () async {
    await preparePurchase();
    verifier.next = (request) => PlayBillingVerification.free(request);
    store.emit(purchase(EntitlementPlans.starter));
    await tick();
    expect((await service.currentState()).plan, EntitlementPlans.free);

    verifier.next = (request) =>
        verifier.paidFor(EntitlementPlans.starter, request);
    store.emit(purchase(EntitlementPlans.starter, token: 'token-2'));
    await tick();
    expect((await service.currentState()).plan, EntitlementPlans.starter);
  });

  test('restart and expired leases return to Free', () async {
    await preparePurchase();
    verifier.next = (request) =>
        verifier.paidFor(EntitlementPlans.starter, request);
    store.emit(purchase(EntitlementPlans.starter));
    await tick();
    expect((await service.currentState()).plan, EntitlementPlans.starter);
    now = now.add(const Duration(minutes: 16));
    expect((await service.currentState()).plan, EntitlementPlans.free);

    final restarted = PlayBillingEntitlementService(
      FakeStore(),
      FakeVerifier(now: () => now),
      now: () => now,
    );
    addTearDown(restarted.dispose);
    expect((await restarted.currentState()).plan, EntitlementPlans.free);
  });

  test(
    'restore and foreground refresh request current Play purchases',
    () async {
      await service.acceptBillingDisclosure();
      await service.restore();
      expect(store.restoreCalls, 1);
      store.emit(
        purchase(EntitlementPlans.collector, state: PlayPurchaseState.restored),
      );
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.collector);
      await service.refreshForForeground();
      expect(store.restoreCalls, 2);
    },
  );

  test('account switches discard delayed paid verification results', () async {
    await preparePurchase();
    final delayed = Completer<PlayBillingVerification>();
    verifier.next = (_) => delayed.future;
    store.emit(purchase(EntitlementPlans.starter));
    await tick();
    verifier.uid = 'uid-b';
    expect(await service.acceptBillingDisclosure(), isTrue);
    delayed.complete(
      verifier.paidFor(EntitlementPlans.starter, verifier.requests.single),
    );
    await tick();
    expect((await service.currentState()).plan, EntitlementPlans.free);
  });

  test('unavailable store and failed refresh clear a valid lease', () async {
    await preparePurchase();
    verifier.next = (request) =>
        verifier.paidFor(EntitlementPlans.starter, request);
    store.emit(purchase(EntitlementPlans.starter));
    await tick();
    store.available = false;
    expect(
      (await service.currentState()).billingStatus,
      EntitlementBillingStatus.unavailable,
    );
    expect((await service.currentState()).plan, EntitlementPlans.free);
  });

  test('a verifier exception clears the in-memory lease', () async {
    await preparePurchase();
    verifier.next = (request) =>
        verifier.paidFor(EntitlementPlans.starter, request);
    store.emit(purchase(EntitlementPlans.starter));
    await tick();
    verifier.next = (_) => throw StateError('fake verifier unavailable');
    await service.refreshForGatedAction();
    expect((await service.currentState()).plan, EntitlementPlans.free);
  });
}

PlayProduct product(EntitlementPlan plan) => PlayProduct(
  id: plan.playProductId!,
  title: plan.name,
  description: '',
  price: plan.priceLabel,
);

PlayPurchase purchase(
  EntitlementPlan plan, {
  PlayPurchaseState state = PlayPurchaseState.purchased,
  String token = 'token-1',
}) => PlayPurchase(
  productId: plan.playProductId!,
  purchaseToken: token,
  state: state,
);

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 1));

class FakeStore implements PlayBillingStore {
  final StreamController<PlayPurchase> _purchases =
      StreamController<PlayPurchase>.broadcast();
  bool available = true;
  bool unavailable = false;
  List<PlayProduct> products = const <PlayProduct>[];
  int restoreCalls = 0;
  String? buyAccountId;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<PlayPurchase> get purchaseStream => _purchases.stream;

  @override
  Future<bool> buySubscription(
    PlayProduct product,
    String obfuscatedAccountId,
  ) async {
    buyAccountId = obfuscatedAccountId;
    return true;
  }

  @override
  Future<PlayProductQuery> queryProducts(Set<String> productIds) async =>
      PlayProductQuery(products: products, unavailable: unavailable);

  @override
  Future<void> restorePurchases() async => restoreCalls++;

  void emit(PlayPurchase purchase) => _purchases.add(purchase);
}

class FakeVerifier implements PlayBillingVerifier {
  FakeVerifier({required this.now});

  final DateTime Function() now;
  String uid = 'uid-a';
  final List<String> accepts = <String>[];
  final List<String> requests = <String>[];
  FutureOr<PlayBillingVerification> Function(String request)? next;

  @override
  Future<bool> acceptDisclosure(String requestId) async {
    accepts.add(requestId);
    return true;
  }

  @override
  Future<String?> ensureBillingIdentity() async => uid;

  @override
  Future<PlayBillingVerification> verify({
    required String requestId,
    required String productId,
    required String purchaseToken,
  }) async {
    requests.add(requestId);
    return await (next?.call(requestId) ??
        paidFor(
          EntitlementPlans.all.singleWhere(
            (plan) => plan.playProductId == productId,
          ),
          requestId,
        ));
  }

  PlayBillingVerification paidFor(EntitlementPlan plan, String requestId) =>
      PlayBillingVerification.paid(
        requestId: requestId,
        plan: plan,
        productId: plan.playProductId!,
        state: 'active',
        leaseExpiresAt: now().add(const Duration(minutes: 15)),
      );
}
