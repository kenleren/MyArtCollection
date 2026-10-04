import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Sanitized outcomes only: credentials and provider errors stay out of UI/logs.
enum PaidAccountStatus {
  idle,
  signedIn,
  canceled,
  existingAccount,
  unavailable,
}

typedef AccountIdentity = ({String uid, bool anonymous, bool google});

abstract interface class PaidAccountGateway {
  AccountIdentity? get current;
  Stream<AccountIdentity?> get changes;
  Future<Object?> googleCredential();
  Future<void> link(Object credential);
  Future<void> signIn(Object credential);
  Future<void> refreshGoogleSession(Object? credential);
}

class PaidAccountCollision implements Exception {}

class PaidAccountReauthenticationRequired implements Exception {}

/// Runs only after an explicit purchase/restore disclosure. No archive access.
class FirebaseAccountService {
  FirebaseAccountService(this.gateway);
  final PaidAccountGateway gateway;
  PaidAccountStatus status = PaidAccountStatus.idle;
  bool _busy = false;
  Stream<AccountIdentity?> get changes => gateway.changes;
  AccountIdentity? get current => gateway.current;

  Future<String?> ensureGoogleAccount({bool useExistingAccount = false}) async {
    if (_busy) return null;
    if (useExistingAccount && status != PaidAccountStatus.existingAccount) {
      return null;
    }
    _busy = true;
    final initial = gateway.current;
    var interrupted = false;
    // Expected linking keeps the UID. A sign-out or unrelated account change
    // while a native dialog is open must not authorize a pending paid action.
    final observer = gateway.changes.listen((identity) {
      if (initial != null &&
          (identity == null ||
              (!useExistingAccount && identity.uid != initial.uid))) {
        interrupted = true;
      }
    });
    try {
      if (initial?.google == true && !useExistingAccount) {
        try {
          await gateway.refreshGoogleSession(null);
        } on PaidAccountReauthenticationRequired {
          // Recover an interrupted link whose Firebase session still reports
          // the anonymous sign-in provider. Never create or transfer a UID.
          final credential = await gateway.googleCredential();
          if (credential == null) {
            status = PaidAccountStatus.canceled;
            return null;
          }
          if (interrupted || gateway.current != initial) {
            status = PaidAccountStatus.unavailable;
            return null;
          }
          await gateway.refreshGoogleSession(credential);
        }
      } else {
        final credential = await gateway.googleCredential();
        if (credential == null) {
          status = PaidAccountStatus.canceled;
          return null;
        }
        if (interrupted || gateway.current != initial) {
          status = PaidAccountStatus.unavailable;
          return null;
        }
        if (initial?.anonymous == true && !useExistingAccount) {
          await gateway.link(credential);
        } else if (initial == null || useExistingAccount) {
          await gateway.signIn(credential);
        } else {
          status = PaidAccountStatus.unavailable;
          return null;
        }
        await gateway.refreshGoogleSession(credential);
      }
      final identity = gateway.current;
      if (interrupted ||
          identity == null ||
          !identity.google ||
          identity.anonymous) {
        status = PaidAccountStatus.unavailable;
        return null;
      }
      status = PaidAccountStatus.signedIn;
      return identity.uid;
    } on PaidAccountCollision {
      status = PaidAccountStatus.existingAccount;
      return null;
    } catch (_) {
      status = PaidAccountStatus.unavailable;
      return null;
    } finally {
      await observer.cancel();
      _busy = false;
    }
  }
}

class FlutterPaidAccountGateway implements PaidAccountGateway {
  FirebaseAuth get _auth => FirebaseAuth.instance;
  static Future<void>? _googleInitialization;

  static AccountIdentity? _identity(User? user) => user == null
      ? null
      : (
          uid: user.uid,
          anonymous: user.isAnonymous,
          google: user.providerData.any(
            (provider) => provider.providerId == 'google.com',
          ),
        );

  @override
  AccountIdentity? get current => _identity(_auth.currentUser);

  @override
  Stream<AccountIdentity?> get changes =>
      _auth.userChanges().map(_identity).distinct();

  @override
  Future<Object?> googleCredential() async {
    // This slice is Android first. No silent Google sign-in or Drive scopes.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('android_billing_identity_only');
    }
    final google = GoogleSignIn.instance;
    try {
      await (_googleInitialization ??= google.initialize());
      final account = await google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw StateError('missing_identity');
      }
      return GoogleAuthProvider.credential(idToken: idToken);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  @override
  Future<void> link(Object credential) async {
    final user = _auth.currentUser;
    if (user == null || !user.isAnonymous) throw StateError('identity_changed');
    try {
      await user.linkWithCredential(credential as AuthCredential);
    } on FirebaseAuthException catch (error) {
      if (error.code == 'credential-already-in-use' ||
          error.code == 'account-exists-with-different-credential') {
        throw PaidAccountCollision();
      }
      rethrow;
    }
  }

  @override
  Future<void> signIn(Object credential) async {
    await _auth.signInWithCredential(credential as AuthCredential);
  }

  @override
  Future<void> refreshGoogleSession(Object? credential) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('identity_changed');
    // Linking can leave the current token's sign-in provider anonymous. A
    // Google reauthentication makes the server-verified provider explicit.
    if (credential != null) {
      await user.reauthenticateWithCredential(credential as AuthCredential);
    }
    final token = await user.getIdTokenResult(true);
    if (_auth.currentUser?.uid != user.uid) {
      throw StateError('identity_changed');
    }
    if (token.signInProvider != 'google.com') {
      throw PaidAccountReauthenticationRequired();
    }
  }
}
