import 'package:web/web.dart' as web;

import 'external_reference_launch_gateway_base.dart';
import 'external_reference_launch_gateway_web_policy.dart';

ExternalReferenceLaunchGateway createPlatformExternalReferenceLaunchGateway() =>
    WebExternalReferenceLaunchGateway(reserveIsolatedBlankTab);

WebExternalReferenceLaunchReservation? reserveIsolatedBlankTab() {
  final target = 'archivale-external-${DateTime.now().microsecondsSinceEpoch}';
  final reserved = web.window.open('about:blank', target);
  if (reserved == null) return null;
  reserved.opener = null;
  return WebExternalReferenceLaunchReservation(reserved, target);
}

class WebExternalReferenceLaunchReservation
    implements ExternalReferenceLaunchReservation {
  const WebExternalReferenceLaunchReservation(this._reserved, this._target);

  final web.Window _reserved;
  final String _target;

  bool get hasNoOpener => _reserved.opener == null;

  @override
  Future<bool> launch(Uri uri) async {
    try {
      final link = web.HTMLAnchorElement()
        ..href = uri.toString()
        ..target = _target
        ..referrerPolicy = 'no-referrer'
        ..style.display = 'none';
      web.document.body?.append(link);
      link.click();
      link.remove();
      return true;
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
