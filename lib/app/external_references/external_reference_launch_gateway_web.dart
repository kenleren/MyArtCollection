import 'package:web/web.dart' as web;

import 'external_reference_launch_gateway_base.dart';
import 'external_reference_launch_gateway_web_policy.dart';

typedef WebExternalReferenceNavigator =
    bool Function(web.Window reserved, Uri uri);

ExternalReferenceLaunchGateway createPlatformExternalReferenceLaunchGateway() =>
    WebExternalReferenceLaunchGateway(() => reserveIsolatedBlankTab());

WebExternalReferenceLaunchReservation? reserveIsolatedBlankTab({
  WebExternalReferenceNavigator navigator = navigateReservedExternalReference,
}) {
  final target = 'archivale-external-${DateTime.now().microsecondsSinceEpoch}';
  final reserved = web.window.open('about:blank', target);
  if (reserved == null) return null;
  reserved.opener = null;
  return WebExternalReferenceLaunchReservation(reserved, navigator: navigator);
}

class WebExternalReferenceLaunchReservation
    implements ExternalReferenceLaunchReservation {
  WebExternalReferenceLaunchReservation(
    this._reserved, {
    this.navigator = navigateReservedExternalReference,
  });

  final web.Window _reserved;
  final WebExternalReferenceNavigator navigator;

  bool get hasNoOpener => _reserved.opener == null;
  bool get isClosed => _reserved.closed;
  String get documentReferrer => _reserved.document.referrer;
  String get locationHref => _reserved.location.href;

  @override
  Future<bool> launch(Uri uri) async {
    if (_reserved.closed) return false;
    try {
      return navigator(_reserved, uri);
    } catch (_) {
      return false;
    }
  }

  @override
  void close() {
    try {
      _reserved.close();
    } catch (_) {
      // A blocked or already-closed reservation has no further cleanup path.
    }
  }
}

bool navigateReservedExternalReference(web.Window reserved, Uri uri) {
  if (reserved.closed) return false;
  final document = reserved.document;
  final body = document.body;
  if (body == null) return false;
  final link = document.createElement('a') as web.HTMLAnchorElement
    ..href = uri.toString()
    ..referrerPolicy = 'no-referrer';
  body.append(link);
  link.click();
  link.remove();
  return true;
}
