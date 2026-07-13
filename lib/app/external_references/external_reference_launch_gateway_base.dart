enum ExternalReferenceLaunchTarget { native, web }

abstract class ExternalReferenceLaunchReservation {
  Future<bool> launch(Uri uri);

  void close();
}

abstract class ExternalReferenceLaunchGateway {
  ExternalReferenceLaunchTarget get target;

  /// Web launch reservations are created synchronously in the user gesture.
  bool get requiresSynchronousReservation => false;

  ExternalReferenceLaunchReservation? reserveExternalLaunch() => null;

  Future<bool> launchExternal(Uri uri);
}
