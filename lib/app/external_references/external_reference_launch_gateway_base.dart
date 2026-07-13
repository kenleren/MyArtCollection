enum ExternalReferenceLaunchTarget { native, web }

abstract class ExternalReferenceLaunchGateway {
  ExternalReferenceLaunchTarget get target;

  Future<bool> launchExternal(Uri uri);
}
