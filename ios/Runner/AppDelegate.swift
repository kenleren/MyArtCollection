import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentInteractionControllerDelegate {
  private var attachmentPreviewController: UIDocumentInteractionController?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "app.archivale/attachment_viewer",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "openSupportingAttachment",
            let arguments = call.arguments as? [String: Any],
            let uriString = arguments["uri"] as? String,
            let url = URL(string: uriString),
            url.isFileURL else {
        result(false)
        return
      }
      result(self?.previewSupportingAttachment(url) ?? false)
    }
  }

  private func previewSupportingAttachment(_ url: URL) -> Bool {
    let candidate = url.resolvingSymlinksInPath().standardizedFileURL
    guard isSupportingAttachmentPayload(candidate),
          let presenter = activeViewController() else {
      return false
    }
    let controller = UIDocumentInteractionController(url: candidate)
    controller.delegate = self
    attachmentPreviewController = controller
    return controller.presentPreview(animated: true)
  }

  private func isSupportingAttachmentPayload(_ url: URL) -> Bool {
    guard let documentsDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else {
      return false
    }
    let attachmentRoot = documentsDirectory
      .appendingPathComponent("attachments/artworks", isDirectory: true)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let rootPath = attachmentRoot.path.hasSuffix("/")
      ? attachmentRoot.path
      : attachmentRoot.path + "/"
    return url.isFileURL &&
      url.path.hasPrefix(rootPath) &&
      FileManager.default.fileExists(atPath: url.path)
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    activeViewController() ?? UIViewController()
  }

  func documentInteractionControllerDidEndPreview(
    _ controller: UIDocumentInteractionController
  ) {
    attachmentPreviewController = nil
  }

  private func activeViewController() -> UIViewController? {
    let foregroundScene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    return foregroundScene?.windows.first { $0.isKeyWindow }?.rootViewController
  }
}
