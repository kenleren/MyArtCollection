import 'dart:async';
import 'package:my_art_collection/app/account/firebase_account_service.dart';

class FakePaidAccountGateway implements PaidAccountGateway {
  @override
  AccountIdentity? current = (uid: 'uid-a', anonymous: true, google: false);
  final events = StreamController<AccountIdentity?>.broadcast(sync: true);
  final calls = <String>[];
  Future<Object?> Function()? credentialNext;
  bool collision = false;
  bool needsReauthentication = false;
  @override
  Stream<AccountIdentity?> get changes => events.stream;
  void change(AccountIdentity? identity) {
    current = identity;
    events.add(identity);
  }

  @override
  Future<Object?> googleCredential() async {
    calls.add('google');
    return credentialNext == null ? Object() : credentialNext!();
  }

  @override
  Future<void> link(Object credential) async {
    calls.add('link');
    if (collision) throw PaidAccountCollision();
    change((uid: current!.uid, anonymous: false, google: true));
  }

  @override
  Future<void> signIn(Object credential) async {
    calls.add('sign-in');
    change((uid: 'returning-uid', anonymous: false, google: true));
  }

  @override
  Future<void> refreshGoogleSession(Object? credential) async {
    calls.add('refresh');
    if (needsReauthentication && credential == null) {
      throw PaidAccountReauthenticationRequired();
    }
  }
}
