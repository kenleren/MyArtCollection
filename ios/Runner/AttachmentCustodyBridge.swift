import Foundation
import Flutter

@_silgen_name("AttachmentCustodyExecute")
private func attachmentCustodyExecute(
  _ flutterRoot: UnsafePointer<CChar>,
  _ operation: UnsafePointer<CChar>,
  _ sourcePath: UnsafePointer<CChar>,
  _ operationId: UnsafePointer<CChar>,
  _ artworkId: UnsafePointer<CChar>,
  _ attachmentId: UnsafePointer<CChar>,
  _ canonicalName: UnsafePointer<CChar>
) -> UnsafePointer<CChar>

/// iOS registration for the frozen v1 native attachment-custody contract.
/// The Objective-C++ core shares Android's descriptor-relative implementation;
/// neither platform accepts Dart-supplied destination paths or storage roots.
enum AttachmentCustodyBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "app.archivale/attachment_custody_v1",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      let arguments = call.arguments as? [String: Any] ?? [:]
      let sourcePath = arguments["sourcePath"] as? String ?? ""
      let operationId = arguments["operationId"] as? String ?? ""
      let artworkId = arguments["artworkId"] as? String ?? ""
      let attachmentId = arguments["attachmentId"] as? String ?? ""
      let canonicalName = arguments["canonicalName"] as? String ?? ""
      result(invoke(
        operation: call.method,
        sourcePath: sourcePath,
        operationId: operationId,
        artworkId: artworkId,
        attachmentId: attachmentId,
        canonicalName: canonicalName
      ))
    }
  }

  private static func invoke(
    operation: String,
    sourcePath: String,
    operationId: String,
    artworkId: String,
    attachmentId: String,
    canonicalName: String
  ) -> [String: Any] {
    guard let documentsDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else {
      return ["outcome": "unsupported", "detail": "App-private documents storage is unavailable."]
    }
    return documentsDirectory.path.withCString { root in
      operation.withCString { operation in
        sourcePath.withCString { sourcePath in
          operationId.withCString { operationId in
            artworkId.withCString { artworkId in
              attachmentId.withCString { attachmentId in
                canonicalName.withCString { canonicalName in
                  let response = String(cString: attachmentCustodyExecute(
                    root, operation, sourcePath, operationId, artworkId, attachmentId, canonicalName
                  ))
                  guard let data = response.data(using: .utf8),
                        let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return ["outcome": "ioFailure", "detail": "Invalid native custody response."]
                  }
                  return map
                }
              }
            }
          }
        }
      }
    }
  }
}
