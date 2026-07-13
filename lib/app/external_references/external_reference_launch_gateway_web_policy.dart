import 'external_reference_launch_gateway_base.dart';

typedef ExternalReferenceSynchronousOpener = bool Function(Uri uri);

class WebExternalReferenceLaunchGateway
    implements ExternalReferenceLaunchGateway {
  const WebExternalReferenceLaunchGateway(this.opener);

  final ExternalReferenceSynchronousOpener opener;

  @override
  ExternalReferenceLaunchTarget get target => ExternalReferenceLaunchTarget.web;

  @override
  Future<bool> launchExternal(Uri uri) {
    try {
      return Future<bool>.value(opener(uri));
    } catch (_) {
      return Future<bool>.value(false);
    }
  }
}
