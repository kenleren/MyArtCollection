import 'package:url_launcher/url_launcher.dart';

import 'external_reference_launch_gateway_base.dart';

ExternalReferenceLaunchGateway createPlatformExternalReferenceLaunchGateway() =>
    const NativeExternalReferenceLaunchGateway();

class NativeExternalReferenceLaunchGateway
    implements ExternalReferenceLaunchGateway {
  const NativeExternalReferenceLaunchGateway({
    this.launcher = const UrlLauncherNativeExternalLauncher(),
  });

  final NativeExternalLauncher launcher;

  @override
  ExternalReferenceLaunchTarget get target =>
      ExternalReferenceLaunchTarget.native;

  @override
  Future<bool> launchExternal(Uri uri) async {
    try {
      final supported = await launcher.supportsExternalApplication();
      if (!supported) return false;
      return await launcher.launchExternalApplication(uri);
    } catch (_) {
      return false;
    }
  }
}

abstract class NativeExternalLauncher {
  Future<bool> supportsExternalApplication();
  Future<bool> launchExternalApplication(Uri uri);
}

class UrlLauncherNativeExternalLauncher implements NativeExternalLauncher {
  const UrlLauncherNativeExternalLauncher();

  @override
  Future<bool> supportsExternalApplication() =>
      supportsLaunchMode(LaunchMode.externalApplication);

  @override
  Future<bool> launchExternalApplication(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}
