import CryptoKit
import Darwin
import Foundation

struct CommittedExportMetadata {
  let artifactId: String
  let kind: String
  let subjectId: String?
  let fileName: String
  let mimeType: String
  let byteSize: Int64
  let checksum: String
}

final class PickerExportCopy {
  let url: URL
  let metadata: CommittedExportMetadata
  private let directory: URL

  init(url: URL, metadata: CommittedExportMetadata, directory: URL) {
    self.url = url
    self.metadata = metadata
    self.directory = directory
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  deinit {
    remove()
  }
}

enum ExportArtifactPolicy {
  private static let metadataKeys: Set<String> = [
    "metadata_version", "state", "artifact_id", "kind", "subject_id",
    "file_name", "mime_type", "byte_size", "checksum_sha256",
    "created_at", "warnings",
  ]
  private static let canonicalUtc = try! NSRegularExpression(
    pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:\d{3})?Z$"#
  )

  static func makePickerCopy(
    sourcePath: String,
    suggestedName: String,
    mimeType: String,
    documentsDirectory: URL,
    temporaryRoot: URL = FileManager.default.temporaryDirectory
  ) -> PickerExportCopy? {
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    guard source.path == source.resolvingSymlinksInPath().standardizedFileURL.path,
          let payload = openNoFollow(source),
          let metadataHandle = openNoFollow(URL(fileURLWithPath: source.path + ".json")) else {
      return nil
    }
    defer { try? metadataHandle.close() }

    guard let metadataData = readAll(metadataHandle, maximumBytes: 64 * 1024),
          let metadata = parseMetadata(metadataData),
          metadata.fileName == suggestedName,
          metadata.mimeType == mimeType else {
      try? payload.close()
      return nil
    }
    let directoryName = metadata.kind == "report" ? "reports" : "archives"
    let expected = documentsDirectory
      .appendingPathComponent("generated_exports/\(directoryName)", isDirectory: true)
      .appendingPathComponent(metadata.fileName, isDirectory: false)
      .standardizedFileURL
    guard source.path == expected.path,
          validate(payload, metadata: metadata) else {
      try? payload.close()
      return nil
    }

    let localDirectory = temporaryRoot
      .appendingPathComponent("verified_export_picker", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let localCopy = localDirectory.appendingPathComponent(metadata.fileName)
    do {
      try FileManager.default.createDirectory(
        at: localDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let descriptor = Darwin.open(
        localCopy.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
      let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      guard copyAndValidate(payload, to: output, metadata: metadata) else {
        try? output.close()
        throw CocoaError(.fileWriteUnknown)
      }
      try output.synchronize()
      try output.close()
      try payload.close()
      return PickerExportCopy(url: localCopy, metadata: metadata, directory: localDirectory)
    } catch {
      try? payload.close()
      try? FileManager.default.removeItem(at: localDirectory)
      return nil
    }
  }

  private static func parseMetadata(_ data: Data) -> CommittedExportMetadata? {
    guard let value = try? JSONSerialization.jsonObject(with: data),
          let object = value as? [String: Any],
          Set(object.keys) == metadataKeys,
          object["metadata_version"] as? Int == 1,
          object["state"] as? String == "complete",
          let artifactId = object["artifact_id"] as? String,
          let kind = object["kind"] as? String,
          let fileName = object["file_name"] as? String,
          let mimeType = object["mime_type"] as? String,
          let byteSizeNumber = object["byte_size"] as? NSNumber,
          let checksum = object["checksum_sha256"] as? String,
          let createdAt = object["created_at"] as? String,
          object["warnings"] is [String],
          CFGetTypeID(byteSizeNumber) != CFBooleanGetTypeID(),
          byteSizeNumber.doubleValue == Double(byteSizeNumber.int64Value),
          artifactId.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
          checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          canonicalUtc.firstMatch(
            in: createdAt,
            range: NSRange(createdAt.startIndex..., in: createdAt)
          ) != nil,
          byteSizeNumber.int64Value > 0 else {
      return nil
    }
    let byteSize = byteSizeNumber.int64Value
    let subjectId = object["subject_id"] is NSNull ? nil : object["subject_id"] as? String
    let expectedMime: String
    let expectedExtension: String
    if kind == "report" {
      guard let subjectId,
            subjectId.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
        return nil
      }
      let subjectHash = SHA256.hash(data: Data(subjectId.utf8)).hex
      guard artifactId.hasPrefix("report-\(subjectHash.prefix(24))-") else { return nil }
      expectedMime = "application/pdf"
      expectedExtension = ".pdf"
    } else if kind == "archive" {
      guard subjectId == nil, artifactId.hasPrefix("archive-") else { return nil }
      expectedMime = "application/zip"
      expectedExtension = ".zip"
    } else {
      return nil
    }
    guard fileName == artifactId + expectedExtension,
          mimeType == expectedMime else {
      return nil
    }
    return CommittedExportMetadata(
      artifactId: artifactId,
      kind: kind,
      subjectId: subjectId,
      fileName: fileName,
      mimeType: mimeType,
      byteSize: byteSize,
      checksum: checksum
    )
  }

  private static func openNoFollow(_ url: URL) -> FileHandle? {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      Darwin.close(descriptor)
      return nil
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private static func validate(
    _ handle: FileHandle,
    metadata: CommittedExportMetadata
  ) -> Bool {
    guard let digest = digest(handle) else { return false }
    return digest.size == metadata.byteSize && digest.checksum == metadata.checksum
  }

  private static func copyAndValidate(
    _ input: FileHandle,
    to output: FileHandle,
    metadata: CommittedExportMetadata
  ) -> Bool {
    do {
      try input.seek(toOffset: 0)
      var hash = SHA256()
      var total: Int64 = 0
      while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
        try output.write(contentsOf: data)
        hash.update(data: data)
        total += Int64(data.count)
      }
      return total == metadata.byteSize && hash.finalize().hex == metadata.checksum
    } catch {
      return false
    }
  }

  private static func digest(_ handle: FileHandle) -> (size: Int64, checksum: String)? {
    do {
      try handle.seek(toOffset: 0)
      var hash = SHA256()
      var total: Int64 = 0
      while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
        hash.update(data: data)
        total += Int64(data.count)
      }
      try handle.seek(toOffset: 0)
      return (total, hash.finalize().hex)
    } catch {
      return nil
    }
  }

  private static func readAll(_ handle: FileHandle, maximumBytes: Int) -> Data? {
    do {
      let data = try handle.readToEnd() ?? Data()
      return data.isEmpty || data.count > maximumBytes ? nil : data
    } catch {
      return nil
    }
  }
}

private extension Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
