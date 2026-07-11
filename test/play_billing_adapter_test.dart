import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/billing/entitlement_plan.dart';
import 'package:my_art_collection/app/billing/play_billing_adapter.dart';
import 'package:my_art_collection/app/research/firebase_research_runtime.dart';

void main() {
  late FakeStore store;
  late FakeVerifier verifier;
  late FakeClock clock;
  late PlayBillingEntitlementService service;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 7, 11, 12));
    store = FakeStore();
    verifier = FakeVerifier();
    service = PlayBillingEntitlementService(store, verifier, clock: clock);
  });

  tearDown(() => service.dispose());

  Future<void> preparePurchase() async {
    store.products = <PlayProduct>[product(EntitlementPlans.starter)];
    expect(await service.acceptBillingDisclosure(), isTrue);
  }

  Future<Completer<PlayBillingVerification>>
  deferOlderVerificationThenInstallNewerLease() async {
    await preparePurchase();
    final delayed = Completer<PlayBillingVerification>();
    verifier.next = (_) => delayed.future;
    store.emit(purchase(EntitlementPlans.starter, token: 'older-token'));
    await tick();
    verifier.next = (request) =>
        verifier.paidFor(EntitlementPlans.starter, request);
    store.emit(purchase(EntitlementPlans.starter, token: 'newer-token'));
    await tick();
    expect((await service.currentState()).plan, EntitlementPlans.starter);
    return delayed;
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

  test(
    'pending and recovery outcomes retain Free authority and publish sanitized progress',
    () async {
      final states = <EntitlementState>[];
      final subscription = service.stateChanges.listen(states.add);
      addTearDown(subscription.cancel);
      await preparePurchase();

      store.emit(
        purchase(
          EntitlementPlans.starter,
          state: PlayPurchaseState.pending,
          token: 'play-pending',
        ),
      );
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.free);
      expect(states.last.presentation, EntitlementPresentation.playPending);

      for (final presentation in <EntitlementPresentation>[
        EntitlementPresentation.verificationPending,
        EntitlementPresentation.inFlight,
        EntitlementPresentation.delayedVerification,
        EntitlementPresentation.acknowledgementRecovery,
      ]) {
        verifier.next = (request) =>
            PlayBillingVerification.free(request, presentation: presentation);
        store.emit(
          purchase(
            EntitlementPlans.starter,
            token: 'free-${presentation.name}',
          ),
        );
        await tick();
        final state = await service.currentState();
        expect(state.plan, EntitlementPlans.free);
        expect(state.presentation, presentation);
        expect(states.last.plan, EntitlementPlans.free);
        expect(states.last.presentation, presentation);
      }
    },
  );

  test(
    'delayed verification publishes pending, verified paid, and verified Free states',
    () async {
      final states = <EntitlementState>[];
      final subscription = service.stateChanges.listen(states.add);
      addTearDown(subscription.cancel);
      await preparePurchase();
      final delayed = Completer<PlayBillingVerification>();
      verifier.next = (_) => delayed.future;

      store.emit(purchase(EntitlementPlans.starter, token: 'delayed-paid'));
      await tick();
      expect(states.last.plan, EntitlementPlans.free);
      expect(
        states.last.presentation,
        EntitlementPresentation.verificationPending,
      );

      delayed.complete(
        verifier.paidFor(EntitlementPlans.starter, verifier.requests.single),
      );
      await tick();
      expect(states.last.plan, EntitlementPlans.starter);
      expect(states.last.presentation, EntitlementPresentation.idle);

      verifier.next = (request) => PlayBillingVerification.free(request);
      store.emit(purchase(EntitlementPlans.starter, token: 'verified-free'));
      await tick();
      expect(states.last.plan, EntitlementPlans.free);
      expect(states.last.presentation, EntitlementPresentation.idle);
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

  test(
    'verified grace and cancellation states are safe for UI presentation',
    () async {
      await preparePurchase();
      verifier.next = (request) =>
          verifier.paidFor(EntitlementPlans.starter, request, state: 'grace');
      store.emit(purchase(EntitlementPlans.starter, token: 'grace-token'));
      await tick();
      expect(
        (await service.currentState()).lifecycle,
        EntitlementLifecycle.grace,
      );

      verifier.next = (request) => verifier.paidFor(
        EntitlementPlans.starter,
        request,
        state: 'canceled',
      );
      store.emit(purchase(EntitlementPlans.starter, token: 'canceled-token'));
      await tick();
      expect(
        (await service.currentState()).lifecycle,
        EntitlementLifecycle.canceledThroughExpiry,
      );
    },
  );

  test('restart and expired leases return to Free', () async {
    await preparePurchase();
    verifier.next = (request) =>
        verifier.paidFor(EntitlementPlans.starter, request);
    store.emit(purchase(EntitlementPlans.starter));
    await tick();
    expect((await service.currentState()).plan, EntitlementPlans.starter);
    clock.advance(const Duration(minutes: 16));
    expect((await service.currentState()).plan, EntitlementPlans.free);

    final restarted = PlayBillingEntitlementService(
      FakeStore(),
      FakeVerifier(),
      clock: clock,
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
    final states = <EntitlementState>[];
    final subscription = service.stateChanges.listen(states.add);
    addTearDown(subscription.cancel);
    await preparePurchase();
    verifier.next = (request) =>
        verifier.paidFor(EntitlementPlans.starter, request);
    store.emit(purchase(EntitlementPlans.starter));
    await tick();
    verifier.next = (_) => throw StateError('fake verifier unavailable');
    await service.refreshForGatedAction();
    expect((await service.currentState()).plan, EntitlementPlans.free);
    await tick();
    expect(states.last.plan, EntitlementPlans.free);
  });

  test(
    'foreground failure, account change, and lease expiry publish visible Free fallbacks',
    () async {
      final states = <EntitlementState>[];
      final subscription = service.stateChanges.listen(states.add);
      addTearDown(subscription.cancel);
      await preparePurchase();
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      expect(states.last.plan, EntitlementPlans.starter);

      store.available = false;
      await service.refreshForForeground();
      expect(states.last.plan, EntitlementPlans.free);

      store.available = true;
      await preparePurchase();
      store.emit(purchase(EntitlementPlans.starter, token: 'account-change'));
      await tick();
      service.handleAccountChange();
      await tick();
      expect(states.last.plan, EntitlementPlans.free);

      await preparePurchase();
      store.emit(purchase(EntitlementPlans.starter, token: 'lease-expiry'));
      await tick();
      expect(states.last.plan, EntitlementPlans.starter);
      clock.advance(const Duration(minutes: 15));
      expect((await service.currentState()).plan, EntitlementPlans.free);
      await tick();
      expect(states.last.plan, EntitlementPlans.free);
    },
  );

  test(
    'an unavailable refresh preflight clears a lease and fences older verification',
    () async {
      final delayed = await deferOlderVerificationThenInstallNewerLease();
      final unavailable = Completer<bool>();
      store.availabilityNext = () => unavailable.future;

      final refresh = service.refreshForGatedAction();
      await tick();
      store.availabilityNext = null;
      expect((await service.currentState()).plan, EntitlementPlans.free);
      unavailable.complete(false);
      await refresh;

      delayed.complete(
        verifier.paidFor(EntitlementPlans.starter, verifier.requests.first),
      );
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'a failed restore clears a lease and fences older verification',
    () async {
      final delayed = await deferOlderVerificationThenInstallNewerLease();
      final failedRestore = Completer<void>();
      store.restoreNext = () => failedRestore.future;

      final restore = service.restore();
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.free);
      failedRestore.completeError(StateError('fake restore failure'));
      await restore;

      delayed.complete(
        verifier.paidFor(EntitlementPlans.starter, verifier.requests.first),
      );
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'a failed purchase preflight clears a lease and fences older verification',
    () async {
      final delayed = await deferOlderVerificationThenInstallNewerLease();
      final unavailable = Completer<bool>();
      store.availabilityNext = () => unavailable.future;

      final buying = service.purchase(EntitlementPlans.starter);
      await tick();
      store.availabilityNext = null;
      expect((await service.currentState()).plan, EntitlementPlans.free);
      unavailable.complete(false);
      expect(await buying, isFalse);

      delayed.complete(
        verifier.paidFor(EntitlementPlans.starter, verifier.requests.first),
      );
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'sign-out clears an existing paid lease when current state is read',
    () async {
      await preparePurchase();
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.starter);

      verifier.uid = null;
      expect((await service.currentState()).plan, EntitlementPlans.free);
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
    },
  );

  test(
    'lease expiry is bounded by monotonic elapsed time despite wall rollback',
    () async {
      await preparePurchase();
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      clock.moveWall(const Duration(days: -1));
      clock.advanceMonotonic(const Duration(minutes: 14, seconds: 59));
      expect((await service.currentState()).plan, EntitlementPlans.starter);
      clock.advanceMonotonic(const Duration(seconds: 1));
      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'verifier delay is subtracted from the monotonic lease deadline',
    () async {
      await preparePurchase();
      final delayed = Completer<PlayBillingVerification>();
      verifier.next = (_) => delayed.future;
      store.emit(purchase(EntitlementPlans.starter));
      await tick();

      clock.advanceMonotonic(const Duration(minutes: 5));
      delayed.complete(
        verifier.paidFor(EntitlementPlans.starter, verifier.requests.single),
      );
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.starter);

      clock.advanceMonotonic(const Duration(minutes: 9, seconds: 59));
      expect((await service.currentState()).plan, EntitlementPlans.starter);
      clock.advanceMonotonic(const Duration(seconds: 1));
      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test('an already elapsed verifier lease is rejected', () async {
    await preparePurchase();
    final delayed = Completer<PlayBillingVerification>();
    verifier.next = (_) => delayed.future;
    store.emit(purchase(EntitlementPlans.starter));
    await tick();

    clock.advanceMonotonic(const Duration(minutes: 15));
    delayed.complete(
      verifier.paidFor(EntitlementPlans.starter, verifier.requests.single),
    );
    await tick();
    expect((await service.currentState()).plan, EntitlementPlans.free);
  });

  test(
    'stale disclosure identity completion cannot restore account state',
    () async {
      final identity = Completer<String?>();
      verifier.identityNext = () => identity.future;
      final accepting = service.acceptBillingDisclosure();
      await tick();
      service.handleAccountChange();
      identity.complete('uid-a');

      expect(await accepting, isFalse);
      expect(verifier.accepts, isEmpty);
    },
  );

  test(
    'account changes during a product query cannot start purchase',
    () async {
      await preparePurchase();
      final query = Completer<PlayProductQuery>();
      store.queryNext = (_) => query.future;
      final purchasing = service.purchase(EntitlementPlans.starter);
      await tick();
      service.handleAccountChange();
      query.complete(
        PlayProductQuery(
          products: <PlayProduct>[product(EntitlementPlans.starter)],
        ),
      );

      expect(await purchasing, isFalse);
      expect(store.buyAccountId, isNull);
    },
  );

  test(
    'account changes during restore cannot leave a paid lease active',
    () async {
      await preparePurchase();
      final restoring = Completer<void>();
      store.restoreNext = () => restoring.future;
      final restore = service.restore();
      await tick();
      service.handleAccountChange();
      restoring.complete();
      await restore;

      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'account changes during a purchase launch cannot restore paid state',
    () async {
      await preparePurchase();
      final buying = Completer<bool>();
      store.buyNext = (_, _) => buying.future;
      final purchase = service.purchase(EntitlementPlans.starter);
      await tick();
      service.handleAccountChange();
      buying.complete(true);

      expect(await purchase, isFalse);
      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'account changes during foreground refresh cannot retain a lease',
    () async {
      await preparePurchase();
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      final restoring = Completer<void>();
      store.restoreNext = () => restoring.future;
      final refresh = service.refreshForForeground();
      await tick();
      service.handleAccountChange();
      restoring.complete();
      await refresh;

      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'callable resolution is lazy and uses the required App Check options',
    () async {
      final wallNow = DateTime.utc(2026, 7, 11, 12);
      final runtime = FakeFirebaseRuntime();
      final callables = FakeCallableFactory(
        onCall: (name, data) => switch (name) {
          'acceptPlayBillingDisclosure' => <String, Object>{
            'version': 'play-billing-v1',
            'requestId': data['requestId']!,
            'status': 'accepted',
          },
          'verifyPlaySubscription' => <String, Object>{
            'version': 'play-billing-v1',
            'requestId': data['requestId']!,
            'state': 'active',
            'planId': EntitlementPlans.starter.id,
            'productId': EntitlementPlans.starter.playProductId!,
            'verifiedAt': wallNow.toIso8601String(),
            'playExpiresAt': wallNow
                .add(const Duration(days: 30))
                .toIso8601String(),
            'leaseExpiresAt': wallNow
                .add(const Duration(minutes: 15))
                .toIso8601String(),
          },
          _ => throw StateError('unexpected callable'),
        },
      );
      final firebaseVerifier = FirebasePlayBillingVerifier(
        runtime,
        callableFactory: callables,
        now: () => wallNow,
      );

      expect(runtime.calls, isEmpty);
      expect(callables.invocations, isEmpty);
      expect(await firebaseVerifier.acceptDisclosure('before-init'), isFalse);
      expect(callables.invocations, isEmpty);

      expect(await firebaseVerifier.ensureBillingIdentity(), 'uid-a');
      expect(await firebaseVerifier.acceptDisclosure('disclosure-1'), isTrue);
      final verified = await firebaseVerifier.verify(
        requestId: 'verify-1',
        productId: EntitlementPlans.starter.playProductId!,
        purchaseToken: 'fake-token',
      );

      expect(verified.leaseDuration, const Duration(minutes: 15));
      expect(callables.invocations.map((item) => item.name), <String>[
        'acceptPlayBillingDisclosure',
        'verifyPlaySubscription',
      ]);
      for (final invocation in callables.invocations) {
        expect(invocation.options.region, 'us-central1');
        expect(invocation.options.timeout, const Duration(seconds: 60));
        expect(invocation.options.limitedUseAppCheckToken, isTrue);
      }
    },
  );

  test('verifier allowlists only sanitized Free recovery reasons', () async {
    for (final entry in <(String, EntitlementPresentation)>[
      ('verification_pending', EntitlementPresentation.verificationPending),
      ('in_flight', EntitlementPresentation.inFlight),
      ('delayed_verification', EntitlementPresentation.delayedVerification),
      (
        'acknowledgement_recovery',
        EntitlementPresentation.acknowledgementRecovery,
      ),
      ('unexpected_provider_detail', EntitlementPresentation.idle),
    ]) {
      final runtime = FakeFirebaseRuntime();
      final verifier = FirebasePlayBillingVerifier(
        runtime,
        callableFactory: FakeCallableFactory(
          onCall: (_, data) => <String, Object>{
            'version': 'play-billing-v1',
            'requestId': data['requestId']!,
            'state': 'free',
            'reason': entry.$1,
          },
        ),
      );
      expect(await verifier.ensureBillingIdentity(), isNotNull);
      final result = await verifier.verify(
        requestId: 'request-${entry.$1}',
        productId: EntitlementPlans.starter.playProductId!,
        purchaseToken: 'test-token',
      );
      expect(result.isPaid, isFalse);
      expect(result.presentation, entry.$2);
    }
  });

  test(
    'verifier rejects malformed and materially future server timestamps',
    () async {
      final now = DateTime.utc(2026, 7, 11, 12);
      final runtime = FakeFirebaseRuntime();
      Object? response = <String, Object>{
        'version': 'play-billing-v1',
        'requestId': 'verify-1',
        'state': 'active',
        'planId': EntitlementPlans.starter.id,
        'productId': EntitlementPlans.starter.playProductId!,
        'verifiedAt': now.add(const Duration(hours: 25)).toIso8601String(),
        'playExpiresAt': now.add(const Duration(days: 30)).toIso8601String(),
        'leaseExpiresAt': now
            .add(const Duration(hours: 25))
            .add(const Duration(minutes: 15))
            .toIso8601String(),
      };
      final verifier = FirebasePlayBillingVerifier(
        runtime,
        callableFactory: FakeCallableFactory(onCall: (_, _) => response),
        now: () => now,
      );
      await verifier.ensureBillingIdentity();

      expect(
        (await verifier.verify(
          requestId: 'verify-1',
          productId: EntitlementPlans.starter.playProductId!,
          purchaseToken: 'fake-token',
        )).isPaid,
        isFalse,
      );
      response = <String, Object>{
        ...(response as Map<String, Object>),
        'verifiedAt': 'not-a-timestamp',
      };
      expect(
        (await verifier.verify(
          requestId: 'verify-1',
          productId: EntitlementPlans.starter.playProductId!,
          purchaseToken: 'fake-token',
        )).isPaid,
        isFalse,
      );
    },
  );

  test(
    'clock-behind receipt receives at most a fifteen-minute lease',
    () async {
      final deviceNow = DateTime.utc(2026, 7, 11, 11);
      final serverNow = deviceNow.add(const Duration(hours: 1));
      final verifier = FirebasePlayBillingVerifier(
        FakeFirebaseRuntime(),
        callableFactory: FakeCallableFactory(
          onCall: (_, data) => <String, Object>{
            'version': 'play-billing-v1',
            'requestId': data['requestId']!,
            'state': 'active',
            'planId': EntitlementPlans.starter.id,
            'productId': EntitlementPlans.starter.playProductId!,
            'verifiedAt': serverNow.toIso8601String(),
            'playExpiresAt': serverNow
                .add(const Duration(days: 30))
                .toIso8601String(),
            'leaseExpiresAt': serverNow
                .add(const Duration(minutes: 15))
                .toIso8601String(),
          },
        ),
        now: () => deviceNow,
      );
      await verifier.ensureBillingIdentity();

      final verification = await verifier.verify(
        requestId: 'verify-1',
        productId: EntitlementPlans.starter.playProductId!,
        purchaseToken: 'fake-token',
      );
      expect(verification.leaseDuration, const Duration(minutes: 15));
    },
  );
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
  FutureOr<bool> Function()? availabilityNext;
  FutureOr<bool> Function(PlayProduct product, String accountId)? buyNext;
  FutureOr<PlayProductQuery> Function(Set<String> productIds)? queryNext;
  FutureOr<void> Function()? restoreNext;

  @override
  Future<bool> isAvailable() async =>
      await (availabilityNext?.call() ?? available);

  @override
  Stream<PlayPurchase> get purchaseStream => _purchases.stream;

  @override
  Future<bool> buySubscription(
    PlayProduct product,
    String obfuscatedAccountId,
  ) async {
    buyAccountId = obfuscatedAccountId;
    return await (buyNext?.call(product, obfuscatedAccountId) ?? true);
  }

  @override
  Future<PlayProductQuery> queryProducts(Set<String> productIds) async =>
      await (queryNext?.call(productIds) ??
          PlayProductQuery(products: products, unavailable: unavailable));

  @override
  Future<void> restorePurchases() async {
    restoreCalls++;
    await restoreNext?.call();
  }

  void emit(PlayPurchase purchase) => _purchases.add(purchase);
}

class FakeVerifier implements PlayBillingVerifier {
  String? uid = 'uid-a';
  final List<String> accepts = <String>[];
  final List<String> requests = <String>[];
  FutureOr<String?> Function()? identityNext;
  FutureOr<PlayBillingVerification> Function(String request)? next;

  @override
  Future<bool> acceptDisclosure(String requestId) async {
    accepts.add(requestId);
    return true;
  }

  @override
  Future<String?> ensureBillingIdentity() async =>
      await (identityNext?.call() ?? uid);

  @override
  String? currentBillingUserId() => uid;

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

  PlayBillingVerification paidFor(
    EntitlementPlan plan,
    String requestId, {
    String state = 'active',
  }) => PlayBillingVerification.paid(
    requestId: requestId,
    plan: plan,
    productId: plan.playProductId!,
    state: state,
    leaseDuration: const Duration(minutes: 15),
  );
}

class FakeClock implements PlayBillingClock {
  FakeClock(this.wall);

  DateTime wall;
  Duration monotonic = Duration.zero;

  @override
  Duration elapsed() => monotonic;

  @override
  DateTime wallNow() => wall;

  void advance(Duration duration) {
    wall = wall.add(duration);
    monotonic += duration;
  }

  void moveWall(Duration duration) => wall = wall.add(duration);

  void advanceMonotonic(Duration duration) => monotonic += duration;
}

class FakeFirebaseRuntime implements FirebaseResearchRuntime {
  final List<String> calls = <String>[];
  String? uid = 'uid-a';

  @override
  Future<String?> authToken({required bool forceRefresh}) async => null;

  @override
  String? currentUserId() => uid;

  @override
  Future<bool> fetchOnlineResearchEnabled() async => false;

  @override
  Future<void> initializeAppCheck() async => calls.add('app-check');

  @override
  Future<void> initializeFirebase() async => calls.add('firebase');

  @override
  Future<String?> limitedUseAppCheckToken({required bool forceRefresh}) async =>
      null;

  @override
  Future<void> signInAnonymously() async => calls.add('anonymous-auth');
}

class FakeCallableFactory implements PlayBillingCallableFactory {
  FakeCallableFactory({required this.onCall});

  final Object? Function(String name, Map<String, Object> data) onCall;
  final List<FakeCallableInvocation> invocations = <FakeCallableInvocation>[];

  @override
  PlayBillingCallable create(
    String name, {
    required PlayBillingCallableOptions options,
  }) {
    final invocation = FakeCallableInvocation(name, options);
    invocations.add(invocation);
    return _FakeCallable(invocation, onCall);
  }
}

class FakeCallableInvocation {
  FakeCallableInvocation(this.name, this.options);

  final String name;
  final PlayBillingCallableOptions options;
}

class _FakeCallable implements PlayBillingCallable {
  _FakeCallable(this._invocation, this._onCall);

  final FakeCallableInvocation _invocation;
  final Object? Function(String name, Map<String, Object> data) _onCall;

  @override
  Future<Object?> call(Map<String, Object> data) async =>
      _onCall(_invocation.name, data);
}
