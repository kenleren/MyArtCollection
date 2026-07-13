import 'external_reference_launch_gateway_base.dart';

typedef ExternalReferenceSynchronousReservationFactory =
    ExternalReferenceLaunchReservation? Function();

class WebExternalReferenceLaunchGateway
    implements ExternalReferenceLaunchGateway {
  const WebExternalReferenceLaunchGateway(this.reservationFactory);

  final ExternalReferenceSynchronousReservationFactory reservationFactory;

  @override
  ExternalReferenceLaunchTarget get target => ExternalReferenceLaunchTarget.web;

  @override
  bool get requiresSynchronousReservation => true;

  @override
  ExternalReferenceLaunchReservation? reserveExternalLaunch() {
    try {
      return reservationFactory();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> launchExternal(Uri uri) async => false;
}
