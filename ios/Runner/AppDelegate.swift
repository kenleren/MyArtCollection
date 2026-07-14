import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentInteractionControllerDelegate, UIDocumentPickerDelegate {
  private var attachmentPreviewController: UIDocumentInteractionController?
  private var pendingExportSaveResult: FlutterResult?
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
    let exportChannel = FlutterMethodChannel(
      name: "app.archivale/export_destination",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    exportChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "saveCopy",
            let arguments = call.arguments as? [String: Any],
            let sourcePath = arguments["sourcePath"] as? String,
            let suggestedName = arguments["suggestedName"] as? String,
            let mimeType = arguments["mimeType"] as? String,
            let self else {
        result("unavailable")
        return
      }
      self.presentExportSaveCopy(
        sourcePath: sourcePath,
        suggestedName: suggestedName,
        mimeType: mimeType,
        result: result
      )
    }
  }

  private func presentExportSaveCopy(
    sourcePath: String,
    suggestedName: String,
    mimeType: String,
    result: @escaping FlutterResult
  ) {
    let safeName = !suggestedName.isEmpty &&
      suggestedName.count <= 160 &&
      !suggestedName.contains("/") &&
      !suggestedName.contains("\\")
    guard pendingExportSaveResult == nil,
          safeName,
          mimeType == "application/pdf" || mimeType == "application/zip",
          let presenter = activeViewController() else {
      result("unavailable")
      return
    }
    let candidate = URL(fileURLWithPath: sourcePath)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    guard isGeneratedExport(candidate),
          candidate.lastPathComponent == suggestedName else {
      result("unavailable")
      return
    }
    let picker = UIDocumentPickerViewController(
      forExporting: [candidate],
      asCopy: true
    )
    picker.delegate = self
    pendingExportSaveResult = result
    presenter.present(picker, animated: true)
  }

  private func isGeneratedExport(_ url: URL) -> Bool {
    guard let documentsDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else {
      return false
    }
    let exportRoot = documentsDirectory
      .appendingPathComponent("generated_exports", isDirectory: true)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let rootPath = exportRoot.path.hasSuffix("/")
      ? exportRoot.path
      : exportRoot.path + "/"
    return url.isFileURL &&
      url.path.hasPrefix(rootPath) &&
      FileManager.default.fileExists(atPath: url.path)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    let result = pendingExportSaveResult
    pendingExportSaveResult = nil
    result?(urls.isEmpty ? "unavailable" : "completed")
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pendingExportSaveResult
    pendingExportSaveResult = nil
    result?("dismissed")
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
