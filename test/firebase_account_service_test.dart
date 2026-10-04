import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/account/firebase_account_service.dart';
import 'support/fake_paid_account_gateway.dart';

void main() {
  late FakePaidAccountGateway gateway;
  late FirebaseAccountService service;
  setUp(() {
    gateway = FakePaidAccountGateway();
    service = FirebaseAccountService(gateway);
  });
  tearDown(() => gateway.events.close());
  test(
    'construction never starts auth; anonymous linking preserves UID',
    () async {
      expect(gateway.calls, isEmpty);
      expect(await service.ensureGoogleAccount(), 'uid-a');
      expect(gateway.calls, ['google', 'link', 'refresh']);
      expect(service.status, PaidAccountStatus.signedIn);
    },
  );
  test(
    'interrupted link reauthenticates Google without replacing UID',
    () async {
      gateway.current = (uid: 'uid-a', anonymous: false, google: true);
      gateway.needsReauthentication = true;
      expect(await service.ensureGoogleAccount(), 'uid-a');
      expect(gateway.calls, ['refresh', 'google', 'refresh']);
    },
  );
  test('fresh installation signs in to the returning account', () async {
    gateway.current = null;
    expect(await service.ensureGoogleAccount(), 'returning-uid');
    expect(gateway.calls, ['google', 'sign-in', 'refresh']);
  });
  test(
    'canceling Google creates no account and leaves anonymous identity',
    () async {
      gateway.credentialNext = () async => null;
      expect(await service.ensureGoogleAccount(), isNull);
      expect(gateway.calls, ['google']);
      expect(gateway.current?.uid, 'uid-a');
      expect(service.status, PaidAccountStatus.canceled);
    },
  );
  test(
    'collision keeps old UID until explicit existing-account recovery',
    () async {
      gateway.collision = true;
      expect(await service.ensureGoogleAccount(), isNull);
      expect(service.status, PaidAccountStatus.existingAccount);
      expect(gateway.current?.uid, 'uid-a');
      expect(gateway.calls, isNot(contains('sign-in')));
      expect(
        await service.ensureGoogleAccount(useExistingAccount: true),
        'returning-uid',
      );
      expect(gateway.calls.where((value) => value == 'sign-in'), hasLength(1));
    },
  );
  test('sign-out during Google dialog fences the pending operation', () async {
    final credential = Completer<Object?>();
    gateway.credentialNext = () => credential.future;
    final result = service.ensureGoogleAccount();
    gateway.change(null);
    credential.complete(Object());
    expect(await result, isNull);
    expect(gateway.calls, ['google']);
  });
  test('provider-only change is observable without changing UID', () async {
    final identities = <AccountIdentity?>[];
    final subscription = service.changes.listen(identities.add);
    gateway.change((uid: 'uid-a', anonymous: false, google: true));
    gateway.change((uid: 'uid-a', anonymous: false, google: false));
    expect(identities, hasLength(2));
    await subscription.cancel();
  });
  test(
    'existing Google session refreshes without a second native prompt',
    () async {
      gateway.current = (uid: 'uid-a', anonymous: false, google: true);
      expect(await service.ensureGoogleAccount(), 'uid-a');
      expect(gateway.calls, ['refresh']);
    },
  );
}
