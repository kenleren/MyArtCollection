import 'external_reference_launch_gateway_base.dart';
import 'external_reference_launch_gateway_stub.dart'
    if (dart.library.io) 'external_reference_launch_gateway_native.dart'
    if (dart.library.html) 'external_reference_launch_gateway_web.dart';

export 'external_reference_launch_gateway_base.dart';

ExternalReferenceLaunchGateway createSystemExternalReferenceLaunchGateway() =>
    createPlatformExternalReferenceLaunchGateway();
