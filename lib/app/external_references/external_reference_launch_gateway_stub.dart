import 'external_reference_launch_gateway_base.dart';

ExternalReferenceLaunchGateway createPlatformExternalReferenceLaunchGateway() =>
    const _UnsupportedExternalReferenceLaunchGateway();

class _UnsupportedExternalReferenceLaunchGateway
    implements ExternalReferenceLaunchGateway {
  const _UnsupportedExternalReferenceLaunchGateway();

  @override
  ExternalReferenceLaunchTarget get target =>
      ExternalReferenceLaunchTarget.native;

  @override
  Future<bool> launchExternal(Uri uri) async => false;
}
