import 'package:web/web.dart' as web;

import 'external_reference_launch_gateway_base.dart';
import 'external_reference_launch_gateway_web_policy.dart';

ExternalReferenceLaunchGateway createPlatformExternalReferenceLaunchGateway() =>
    WebExternalReferenceLaunchGateway(
      (uri) => web.window.open(uri.toString(), '_blank') != null,
    );
