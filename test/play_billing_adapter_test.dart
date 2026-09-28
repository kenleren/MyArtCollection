import 'dart:async';
import 'dart:convert';
import 'package:my_art_collection/app/account/firebase_account_service.dart';
import 'support/fake_paid_account_gateway.dart';

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

  test(
    'same-account restore succeeds without a local Play store or receipt',
    () async {
      await preparePurchase();
      store.available = false;
      verifier.restoreAccountNext = (request) =>
          verifier.paidFor(EntitlementPlans.collector, request);
      await service.restore();
      expect((await service.currentState()).plan, EntitlementPlans.collector);
      expect(store.restoreCalls, 0);
      expect(verifier.prepareRequests, isEmpty);
      expect(verifier.requests, isEmpty);
      expect(verifier.restoreRequests, hasLength(1));
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      expect(store.buyAccountId, isNull);
    },
  );

  test('concurrent Restore callers await one account verification', () async {
    await preparePurchase();
    final result = Completer<PlayBillingVerification>();
    verifier.restoreAccountNext = (_) => result.future;
    var firstDone = false;
    var secondDone = false;
    final first = service.restore().then((_) => firstDone = true);
    final second = service.restore().then((_) => secondDone = true);
    await tick();
    expect(firstDone || secondDone, isFalse);
    expect(verifier.restoreRequests, hasLength(1));
    result.complete(
      verifier.paidFor(
        EntitlementPlans.starter,
        verifier.restoreRequests.single,
      ),
    );
    await Future.wait([first, second]);
    expect((await service.currentState()).plan, EntitlementPlans.starter);
    expect(store.restoreCalls, 0);
  });

  test(
    'owned-query receipt is awaited and duplicate events do not extend access',
    () async {
      await preparePurchase();
      final receipt = purchase(EntitlementPlans.starter);
      store.ownedNext = () async => PlayOwnedPurchases(purchases: [receipt]);
      final verified = Completer<PlayBillingVerification>();
      verifier.next = (_) => verified.future;
      var completed = false;
      final restoring = service.restore().then((_) => completed = true);
      await tick();
      expect(completed, isFalse);
      store.emit(receipt);
      await tick();
      expect(verifier.requests, hasLength(1));
      verified.complete(
        verifier.paidFor(EntitlementPlans.starter, verifier.requests.single),
      );
      await restoring;
      clock.advanceMonotonic(const Duration(minutes: 14));
      store.emit(receipt);
      await tick();
      expect(verifier.requests, hasLength(1));
      expect((await service.currentState()).plan, EntitlementPlans.starter);
      clock.advanceMonotonic(const Duration(minutes: 1));
      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'mismatched account response cannot authorize a purchase check',
    () async {
      await preparePurchase();
      verifier.restoreAccountNext = (_) => PlayBillingVerification.free(
        'another-request',
        outcome: 'none',
        reason: 'no_known_purchase',
      );
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      expect(store.restoreCalls, 0);
      expect(store.buyAccountId, isNull);
    },
  );

  test(
    'hold, pause and unavailable account state never launch a second subscription',
    () async {
      await preparePurchase();
      for (final reason in ['on_hold', 'paused', 'temporarily_unavailable']) {
        verifier.restoreAccountNext = (request) => PlayBillingVerification.free(
          request,
          outcome: reason == 'temporarily_unavailable' ? 'unavailable' : 'none',
          reason: reason,
          presentation: reason == 'temporarily_unavailable'
              ? EntitlementPresentation.unavailable
              : EntitlementPresentation.idle,
        );
        expect(await service.purchase(EntitlementPlans.starter), isFalse);
        expect(store.buyAccountId, isNull);
        expect(store.restoreCalls, 0);
        final state = await service.currentState();
        expect(state.plan, EntitlementPlans.free);
        expect(
          state.lifecycle,
          reason == 'on_hold'
              ? EntitlementLifecycle.hold
              : reason == 'paused'
              ? EntitlementLifecycle.paused
              : EntitlementLifecycle.free,
        );
      }
    },
  );

  test(
    'foreground resume fences account verification suspended across sleep',
    () async {
      await preparePurchase();
      final old = Completer<PlayBillingVerification>();
      verifier.restoreAccountNext = (_) => old.future;
      final restoring = service.restore();
      await tick();
      final oldId = verifier.restoreRequests.single;
      clock.moveWall(
        const Duration(hours: 8),
      ); // Android Stopwatch may not advance during sleep.
      verifier.restoreAccountNext = (request) => PlayBillingVerification.free(
        request,
        outcome: 'unavailable',
        presentation: EntitlementPresentation.unavailable,
      );
      await service.refreshForForeground();
      old.complete(verifier.paidFor(EntitlementPlans.starter, oldId));
      await restoring;
      expect(verifier.restoreRequests, hasLength(2));
      expect((await service.currentState()).plan, EntitlementPlans.free);
      expect(store.restoreCalls, 0);
    },
  );

  test(
    'failed resume does not preserve a lease across uncounted device sleep',
    () async {
      await preparePurchase();
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      clock.moveWall(const Duration(hours: 8));
      verifier.restoreAccountNext = (_) =>
          throw StateError('synthetic unavailable');
      await service.refreshForForeground();
      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'ambiguous device receipts fail visibly without guessing the plan',
    () async {
      await preparePurchase();
      store.ownedNext = () async => PlayOwnedPurchases(
        purchases: [
          purchase(EntitlementPlans.starter, token: 'one'),
          purchase(EntitlementPlans.collector, token: 'two'),
        ],
      );
      await service.restore();
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.recoveryExhausted,
      );
      expect(verifier.requests, isEmpty);
      expect(await service.purchase(EntitlementPlans.archive), isFalse);
      expect(store.buyAccountId, isNull);
    },
  );

  test(
    'Restore can reverify a receipt whose older stream request was fenced',
    () async {
      await preparePurchase();
      final receipt = purchase(EntitlementPlans.starter);
      final old = Completer<PlayBillingVerification>();
      verifier.next = (_) => old.future;
      store.emit(receipt);
      await tick();
      final oldId = verifier.requests.single;
      store.ownedNext = () async => PlayOwnedPurchases(purchases: [receipt]);
      verifier.next = (request) =>
          verifier.paidFor(EntitlementPlans.starter, request);
      await service.restore();
      expect(verifier.requests, hasLength(2));
      expect((await service.currentState()).plan, EntitlementPlans.starter);
      old.complete(PlayBillingVerification.free(oldId));
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.starter);
    },
  );

  test(
    'a pending receipt without a token never becomes an empty purchase list',
    () async {
      await preparePurchase();
      store.ownedNext = () async => PlayOwnedPurchases(
        purchases: [
          purchase(
            EntitlementPlans.starter,
            token: '',
            state: PlayPurchaseState.pending,
          ),
        ],
      );
      await service.restore();
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.playPending,
      );
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      expect(store.buyAccountId, isNull);
      expect(verifier.requests, isEmpty);
    },
  );

  test(
    'receipt-present pending restore preserves the bounded recovery budget',
    () async {
      await preparePurchase();
      verifier.next = (request) => PlayBillingVerification.free(
        request,
        outcome: 'pending',
        reason: 'verification_pending',
        presentation: EntitlementPresentation.verificationPending,
      );
      store.ownedNext = () async =>
          PlayOwnedPurchases(purchases: [purchase(EntitlementPlans.starter)]);
      store.emit(
        purchase(EntitlementPlans.starter, state: PlayPurchaseState.pending),
      );
      await tick();
      for (var attempt = 0; attempt < 4; attempt++) {
        await service.restore();
      }
      expect(verifier.restoreRequests, hasLength(2));
      expect(verifier.requests, hasLength(2));
      expect(await service.canRecover(), isFalse);
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.recoveryExhausted,
      );
      expect(store.buyAccountId, isNull);
    },
  );

  test(
    'successful account recovery clears its old pending budget and fallback',
    () async {
      await preparePurchase();
      store.emit(
        purchase(EntitlementPlans.starter, state: PlayPurchaseState.pending),
      );
      await tick();
      verifier.restoreAccountNext = (request) => PlayBillingVerification.free(
        request,
        outcome: 'pending',
        reason: 'verification_pending',
        presentation: EntitlementPresentation.verificationPending,
      );
      await service.restore();
      verifier.restoreAccountNext = (request) =>
          verifier.paidFor(EntitlementPlans.starter, request);
      await service.restore();
      expect((await service.currentState()).plan, EntitlementPlans.starter);
      await service.refreshForForeground();
      expect(verifier.restoreRequests, hasLength(3));
      expect((await service.currentState()).plan, EntitlementPlans.starter);
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.idle,
      );
      expect(await service.canRecover(), isTrue);
    },
  );

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
    'Google cancellation never accepts disclosure or launches billing',
    () async {
      final gateway = FakePaidAccountGateway()
        ..credentialNext = () async => null;
      final callables = FakeCallableFactory(
        onCall: (_, _) => throw StateError('must not call'),
      );
      final firebaseVerifier = FirebasePlayBillingVerifier(
        FakeFirebaseRuntime(),
        accountService: FirebaseAccountService(gateway),
        callableFactory: callables,
      );
      final billing = PlayBillingEntitlementService(store, firebaseVerifier);
      expect(await billing.acceptBillingDisclosure(), isFalse);
      expect(await billing.purchase(EntitlementPlans.starter), isFalse);
      await billing.restore();
      expect(store.restoreCalls, 0);
      expect(callables.invocations, isEmpty);
      await billing.dispose();
      await gateway.events.close();
    },
  );

  test(
    'same UID provider removal fences delayed disclosure completion',
    () async {
      final gateway = FakePaidAccountGateway();
      final response = Completer<Object?>();
      final firebaseVerifier = FirebasePlayBillingVerifier(
        FakeFirebaseRuntime(),
        accountService: FirebaseAccountService(gateway),
        callableFactory: _DeferredCallableFactory(response),
      );
      final billing = PlayBillingEntitlementService(store, firebaseVerifier);
      final accepting = billing.acceptBillingDisclosure();
      await tick();
      gateway.change((uid: 'uid-a', anonymous: false, google: false));
      await tick();
      response.complete({
        'version': 'play-billing-v3',
        'requestId': 'ignored',
        'status': 'accepted',
      });
      expect(await accepting, isFalse);
      expect((await billing.currentState()).plan, EntitlementPlans.free);
      await billing.dispose();
      await gateway.events.close();
    },
  );

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
    'purchase uses the prepared server route after account and receipt recovery',
    () async {
      final order = <String>[];
      store.products = <PlayProduct>[product(EntitlementPlans.starter)];
      verifier.restoreAccountNext = (request) {
        order.add('account');
        return PlayBillingVerification.free(
          request,
          outcome: 'none',
          reason: 'no_known_purchase',
        );
      };
      store.ownedNext = () {
        order.add('receipts');
        return const PlayOwnedPurchases();
      };
      verifier.prepareNext = (request) {
        order.add('prepare');
        return verifier.readyFor(request);
      };
      store.buyNext = (_, _) {
        order.add('buy');
        return true;
      };
      expect(await service.acceptBillingDisclosure(), isTrue);
      expect(await service.purchase(EntitlementPlans.starter), isTrue);
      expect(order, ['account', 'receipts', 'prepare', 'buy']);
      expect(store.buyAccountId, verifier.accountRoute);
      expect(verifier.accepts, hasLength(1));
      expect((await service.currentState()).plan, EntitlementPlans.free);
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      expect({
        verifier.restoreRequests.single,
        verifier.prepareRequests.single,
        verifier.requests.single,
      }, hasLength(3));
    },
  );

  for (final state in ['paid', 'pending', 'unavailable', 'legacy']) {
    test('account $state preflight never prepares another purchase', () async {
      await preparePurchase();
      verifier.restoreAccountNext = (request) => state == 'paid'
          ? verifier.paidFor(EntitlementPlans.collector, request)
          : PlayBillingVerification.free(
              request,
              outcome: state == 'legacy' ? 'rejected' : state,
              reason: switch (state) {
                'pending' => 'verification_pending',
                'legacy' => 'recovery_required',
                _ => 'temporarily_unavailable',
              },
            );
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      expect(verifier.prepareRequests, isEmpty);
      expect(store.buyAccountId, isNull);
    });
  }

  test(
    'a discovered foreign receipt is verified without preparing a route',
    () async {
      await preparePurchase();
      store.ownedNext = () => PlayOwnedPurchases(
        purchases: [purchase(EntitlementPlans.starter, token: 'other-account')],
      );
      verifier.next = (request) => PlayBillingVerification.free(
        request,
        reason: 'account_conflict',
        presentation: EntitlementPresentation.recoveryExhausted,
      );
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      expect(verifier.requests, hasLength(1));
      expect(verifier.prepareRequests, isEmpty);
      expect(store.buyAccountId, isNull);
    },
  );

  for (final change in ['account', 'provider', 'foreground']) {
    test('$change change fences a delayed preparation before buying', () async {
      await preparePurchase();
      final ready = Completer<PlayBillingPreparation>();
      verifier.prepareNext = (_) => ready.future;
      final buying = service.purchase(EntitlementPlans.starter);
      await tick();
      final request = verifier.prepareRequests.single;
      // A second tap cannot dispatch a second preparation while one is pending.
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      if (change == 'foreground') {
        await service.refreshForForeground();
      } else {
        verifier.notifyIdentityChange(change == 'account' ? 'uid-b' : 'uid-a');
        await tick();
      }
      ready.complete(verifier.readyFor(request));
      expect(await buying, isFalse);
      expect(store.buyAccountId, isNull);
      expect((await service.currentState()).plan, EntitlementPlans.free);
      expect(verifier.prepareRequests, hasLength(1));
    });
  }

  test(
    'prepare failure never buys and an explicit retry uses a new request',
    () async {
      await preparePurchase();
      verifier.prepareNext = (_) => throw StateError('synthetic unavailable');
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      expect(store.buyAccountId, isNull);
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.unavailable,
      );
      verifier.prepareNext = null;
      expect(await service.purchase(EntitlementPlans.starter), isTrue);
      expect(verifier.prepareRequests.toSet(), hasLength(2));
      expect(store.buyAccountId, verifier.accountRoute);
    },
  );

  test(
    'purchase routes are obtained afresh for each signed-in account',
    () async {
      final routes = <String>[];
      for (final uid in ['uid-a', 'uid-b', 'uid-a']) {
        verifier.notifyIdentityChange(uid);
        await tick();
        await preparePurchase();
        expect(await service.purchase(EntitlementPlans.starter), isTrue);
        routes.add(store.buyAccountId!);
        store.emit(
          purchase(EntitlementPlans.starter, state: PlayPurchaseState.canceled),
        );
        await tick();
      }
      expect(routes[0], isNot(routes[1]));
      expect(routes[2], routes[0]);
      expect(verifier.prepareRequests, hasLength(3));
    },
  );

  test(
    'purchase and restore do not start before disclosure acceptance',
    () async {
      store.products = <PlayProduct>[product(EntitlementPlans.starter)];
      expect(await service.purchase(EntitlementPlans.starter), isFalse);
      await service.restore();
      expect(store.restoreCalls, 0);
      expect(verifier.prepareRequests, isEmpty);
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

  test(
    'recovery exhaustion bounds disclosure, restore, and verification across repeated recovery events',
    () async {
      await preparePurchase();
      store.emit(
        purchase(
          EntitlementPlans.starter,
          state: PlayPurchaseState.pending,
          token: 'unresolved-purchase',
        ),
      );
      await tick();

      await service.restore();
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.playPending,
      );

      // The UI presents the disclosure before every Restore. Re-accepting for
      // the same unresolved identity must not create a new recovery budget.
      expect(await service.acceptBillingDisclosure(), isTrue);
      await service.refreshForForeground();
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.playPending,
      );

      // Duplicate pending stream events are non-terminal and must not reset
      // the budget before another Restore or foreground Refresh.
      store.emit(
        purchase(
          EntitlementPlans.starter,
          state: PlayPurchaseState.pending,
          token: 'unresolved-purchase',
        ),
      );
      await tick();

      await service.restore();
      await service.refreshForForeground();
      expect(store.restoreCalls, 2);
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.recoveryExhausted,
      );

      // The budget is exhausted for this identity and unresolved operation.
      // Further disclosure, Restore, Refresh, and duplicate pending events
      // must not reach the verifier or Play store.
      expect(await service.canRecover(), isFalse);
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.recoveryExhausted,
      );
      for (var attempt = 0; attempt < 3; attempt++) {
        expect(await service.acceptBillingDisclosure(), isFalse);
        await service.restore();
        await service.refreshForForeground();
        store.emit(
          purchase(
            EntitlementPlans.starter,
            state: PlayPurchaseState.pending,
            token: 'unresolved-purchase',
          ),
        );
        await tick();
      }

      expect(verifier.accepts, hasLength(2));
      expect(store.restoreCalls, 2);
      expect(verifier.requests, isEmpty);
      expect(
        (await service.currentState()).presentation,
        EntitlementPresentation.recoveryExhausted,
      );
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

  test(
    'auth identity notifications immediately clear an active paid lease',
    () async {
      await preparePurchase();
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      expect((await service.currentState()).plan, EntitlementPlans.starter);

      verifier.notifyIdentityChange(null);
      await tick();

      expect((await service.currentState()).plan, EntitlementPlans.free);
    },
  );

  test(
    'local Play unavailability does not erase a current server lease',
    () async {
      await preparePurchase();
      verifier.next = (request) =>
          verifier.paidFor(EntitlementPlans.starter, request);
      store.emit(purchase(EntitlementPlans.starter));
      await tick();
      store.available = false;
      expect(
        (await service.currentState()).billingStatus,
        EntitlementBillingStatus.available,
      );
      expect((await service.currentState()).plan, EntitlementPlans.starter);
    },
  );

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
            'version': 'play-billing-v3',
            'requestId': data['requestId']!,
            'status': 'accepted',
          },
          'verifyPlaySubscription' => <String, Object>{
            'version': 'play-billing-v3',
            'requestId': data['requestId']!,
            'state': 'active',
            'status': 'paid',
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
        accountService: FirebaseAccountService(FakePaidAccountGateway()),
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

  test(
    'preparation uses a strict lazy callable and canonical account route',
    () async {
      const requestId = '11111111-1111-4111-8111-111111111111';
      final route = base64Url
          .encode(List<int>.filled(32, 7))
          .replaceAll('=', '');
      Map<String, Object> ready(Map<String, Object> data) => {
        'version': 'play-billing-v3',
        'requestId': data['requestId']!,
        'status': 'ready',
        'obfuscatedAccountId': route,
        'lifecycleEpoch': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      };
      Object? Function(Map<String, Object>) response = ready;
      final callables = FakeCallableFactory(
        onCall: (_, data) => response(data),
      );
      final verifier = FirebasePlayBillingVerifier(
        FakeFirebaseRuntime(),
        accountService: FirebaseAccountService(FakePaidAccountGateway()),
        callableFactory: callables,
      );
      expect((await verifier.preparePurchase(requestId)).isReady, isFalse);
      expect(callables.invocations, isEmpty);
      await verifier.ensureBillingIdentity();
      final prepared = await verifier.preparePurchase(requestId);
      expect(prepared.isReady, isTrue);
      expect(prepared.obfuscatedAccountId, route);
      final invocation = callables.invocations.single;
      expect(invocation.name, 'preparePlayPurchase');
      expect(invocation.data, {
        'version': 'play-billing-v3',
        'requestId': requestId,
        'billingDisclosureVersion': 'billing-verification-disclosure-v4',
      });
      expect(invocation.options.region, 'us-central1');
      expect(invocation.options.timeout, const Duration(seconds: 60));
      expect(invocation.options.limitedUseAppCheckToken, isTrue);

      for (final changes in <Map<String, Object?>>[
        {'version': 'play-billing-v2'},
        {'requestId': '22222222-2222-4222-8222-222222222222'},
        {'status': 'paid'},
        {'purchaseToken': 'unexpected-field'},
        {'lifecycleEpoch': null},
        {'lifecycleEpoch': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'},
        {'lifecycleEpoch': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'},
        {'obfuscatedAccountId': 'uid-a'},
        {'obfuscatedAccountId': '$route='},
        {'obfuscatedAccountId': '${List.filled(42, 'A').join()}B'},
        {'obfuscatedAccountId': 43},
      ]) {
        response = (data) => {...ready(data), ...changes};
        expect(
          (await verifier.preparePurchase(requestId)).isReady,
          isFalse,
          reason: changes.keys.join(','),
        );
      }
      response = (data) => ready(data)..remove('lifecycleEpoch');
      expect((await verifier.preparePurchase(requestId)).isReady, isFalse);
      response = ready;
      expect(
        (await verifier.preparePurchase('noncanonical-request')).isReady,
        isFalse,
      );
      response = (_) => throw StateError('synthetic network failure');
      expect((await verifier.preparePurchase(requestId)).isReady, isFalse);
    },
  );

  test('preparation allows only its fixed non-paid failure pairs', () async {
    const requestId = '11111111-1111-4111-8111-111111111111';
    for (final entry in <(String, String, EntitlementPresentation)>[
      (
        'rejected',
        'recovery_required',
        EntitlementPresentation.recoveryExhausted,
      ),
      ('rejected', 'unsafe_record', EntitlementPresentation.recoveryExhausted),
      ('unavailable', 'rate_limited', EntitlementPresentation.unavailable),
      ('none', 'recovery_required', EntitlementPresentation.unavailable),
      ('pending', 'unsafe_record', EntitlementPresentation.unavailable),
      ('rejected', 'account_conflict', EntitlementPresentation.unavailable),
    ]) {
      final verifier = FirebasePlayBillingVerifier(
        FakeFirebaseRuntime(),
        accountService: FirebaseAccountService(FakePaidAccountGateway()),
        callableFactory: FakeCallableFactory(
          onCall: (_, data) => {
            'version': 'play-billing-v3',
            'requestId': data['requestId']!,
            'state': 'free',
            'status': entry.$1,
            'reason': entry.$2,
          },
        ),
      );
      await verifier.ensureBillingIdentity();
      final result = await verifier.preparePurchase(requestId);
      expect(result.isReady, isFalse);
      expect(result.obfuscatedAccountId, isNull);
      expect(result.presentation, entry.$3);
    }
  });

  test(
    'account restore uses the bounded v3 callable and rejects mixed or expanded responses',
    () async {
      Object? Function(Map<String, Object>) response = (data) =>
          <String, Object>{
            'version': 'play-billing-v3',
            'requestId': data['requestId']!,
            'state': 'free',
            'status': 'none',
            'reason': 'no_known_purchase',
          };
      final callables = FakeCallableFactory(
        onCall: (_, data) => response(data),
      );
      final verifier = FirebasePlayBillingVerifier(
        FakeFirebaseRuntime(),
        accountService: FirebaseAccountService(FakePaidAccountGateway()),
        callableFactory: callables,
      );
      await verifier.ensureBillingIdentity();
      final result = await verifier.restoreAccount('restore-request');
      expect(result.permitsPurchaseCheck, isTrue);
      expect(callables.invocations.single.name, 'restorePlayEntitlement');
      expect(callables.invocations.single.data, {
        'version': 'play-billing-v3',
        'requestId': 'restore-request',
        'billingDisclosureVersion': 'billing-verification-disclosure-v4',
      });
      for (final changes in <Map<String, Object>>[
        {'version': 'play-billing-v1'},
        {'version': 'play-billing-v2'},
        {'status': 'unknown'},
        {'status': 'pending'},
        {'purchaseToken': 'synthetic-sensitive-field'},
        {'requestId': 'stale-request'},
      ]) {
        response = (data) => <String, Object>{
          'version': 'play-billing-v3',
          'requestId': data['requestId']!,
          'state': 'free',
          'status': 'none',
          'reason': 'no_known_purchase',
          ...changes,
        };
        final rejected = await verifier.restoreAccount('restore-request');
        expect(rejected.isPaid, isFalse);
        expect(rejected.permitsPurchaseCheck, isFalse);
        expect(rejected.reason, isNull);
      }
    },
  );

  test('verifier allowlists only sanitized Free recovery reasons', () async {
    for (final entry in <(String, String, EntitlementPresentation)>[
      (
        'pending',
        'verification_pending',
        EntitlementPresentation.verificationPending,
      ),
      ('pending', 'in_flight', EntitlementPresentation.inFlight),
      (
        'rejected',
        'account_conflict',
        EntitlementPresentation.recoveryExhausted,
      ),
      (
        'unavailable',
        'temporarily_unavailable',
        EntitlementPresentation.unavailable,
      ),
      (
        'rejected',
        'recovery_required',
        EntitlementPresentation.recoveryExhausted,
      ),
      ('rejected', 'unexpected_provider_detail', EntitlementPresentation.idle),
      ('none', 'temporarily_unavailable', EntitlementPresentation.idle),
    ]) {
      final runtime = FakeFirebaseRuntime();
      final verifier = FirebasePlayBillingVerifier(
        runtime,
        accountService: FirebaseAccountService(FakePaidAccountGateway()),
        callableFactory: FakeCallableFactory(
          onCall: (_, data) => <String, Object>{
            'version': 'play-billing-v3',
            'requestId': data['requestId']!,
            'state': 'free',
            'status': entry.$1,
            'reason': entry.$2,
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
      expect(result.presentation, entry.$3);
      if (entry.$3 == EntitlementPresentation.idle) {
        expect(result.reason, isNull);
        expect(result.permitsPurchaseCheck, isFalse);
      }
    }
  });

  test(
    'verifier rejects malformed and materially future server timestamps',
    () async {
      final now = DateTime.utc(2026, 7, 11, 12);
      final runtime = FakeFirebaseRuntime();
      Object? response = <String, Object>{
        'version': 'play-billing-v3',
        'requestId': 'verify-1',
        'state': 'active',
        'status': 'paid',
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
        accountService: FirebaseAccountService(FakePaidAccountGateway()),
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
        accountService: FirebaseAccountService(FakePaidAccountGateway()),
        callableFactory: FakeCallableFactory(
          onCall: (_, data) => <String, Object>{
            'version': 'play-billing-v3',
            'requestId': data['requestId']!,
            'state': 'active',
            'status': 'paid',
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
  FutureOr<PlayOwnedPurchases> Function()? ownedNext;

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

  @override
  Future<PlayOwnedPurchases> queryOwnedPurchases() async {
    if (ownedNext != null) return await ownedNext!();
    if (!await isAvailable()) {
      return const PlayOwnedPurchases(unavailable: true);
    }
    await restorePurchases();
    return const PlayOwnedPurchases();
  }

  void emit(PlayPurchase purchase) => _purchases.add(purchase);
}

class FakeVerifier implements PlayBillingVerifier, PlayBillingIdentityObserver {
  String? uid = 'uid-a';
  final List<String> accepts = <String>[];
  final List<String> requests = <String>[];
  final List<String> restoreRequests = <String>[];
  final List<String> prepareRequests = <String>[];
  FutureOr<PlayBillingPreparation> Function(String request)? prepareNext;
  FutureOr<String?> Function()? identityNext;
  FutureOr<PlayBillingVerification> Function(String request)?
  restoreAccountNext;
  FutureOr<PlayBillingVerification> Function(String request)? next;
  final StreamController<void> _identityChanges =
      StreamController<void>.broadcast();

  @override
  Stream<void> get billingIdentityChanges => _identityChanges.stream;

  void notifyIdentityChange(String? nextUid) {
    uid = nextUid;
    _identityChanges.add(null);
  }

  @override
  Future<PlayBillingVerification> restoreAccount(String requestId) async {
    restoreRequests.add(requestId);
    return await (restoreAccountNext?.call(requestId) ??
        PlayBillingVerification.free(
          requestId,
          outcome: 'none',
          reason: 'no_known_purchase',
        ));
  }

  String get accountRoute => base64Url
      .encode(List<int>.filled(32, uid == 'uid-a' ? 1 : 2))
      .replaceAll('=', '');

  @override
  Future<PlayBillingPreparation> preparePurchase(String requestId) async {
    prepareRequests.add(requestId);
    return await (prepareNext?.call(requestId) ?? readyFor(requestId));
  }

  PlayBillingPreparation readyFor(String requestId) =>
      PlayBillingPreparation.ready(
        requestId: requestId,
        obfuscatedAccountId: accountRoute,
        lifecycleEpoch: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );

  @override
  Future<bool> acceptDisclosure(String requestId) async {
    accepts.add(requestId);
    return true;
  }

  @override
  Future<String?> ensureBillingIdentity({
    bool useExistingAccount = false,
  }) async => await (identityNext?.call() ?? uid);

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
  Map<String, Object>? data;
}

class _FakeCallable implements PlayBillingCallable {
  _FakeCallable(this._invocation, this._onCall);

  final FakeCallableInvocation _invocation;
  final Object? Function(String name, Map<String, Object> data) _onCall;

  @override
  Future<Object?> call(Map<String, Object> data) async {
    _invocation.data = Map.of(data);
    return _onCall(_invocation.name, data);
  }
}

class _DeferredCallableFactory implements PlayBillingCallableFactory {
  _DeferredCallableFactory(this.response);
  final Completer<Object?> response;
  @override
  PlayBillingCallable create(
    String name, {
    required PlayBillingCallableOptions options,
  }) => _DeferredCallable(response);
}

class _DeferredCallable implements PlayBillingCallable {
  _DeferredCallable(this.response);
  final Completer<Object?> response;
  @override
  Future<Object?> call(Map<String, Object> data) async {
    await response.future;
    return {
      'version': 'play-billing-v3',
      'requestId': data['requestId'],
      'status': 'accepted',
    };
  }
}
