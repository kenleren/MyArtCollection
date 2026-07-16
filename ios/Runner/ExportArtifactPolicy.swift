import CryptoKit
import Darwin
import Foundation

@_silgen_name("AttachmentCustodyOpenExportPair")
private func attachmentCustodyOpenExportPair(
  _ flutterRoot: UnsafePointer<CChar>,
  _ sourcePath: UnsafePointer<CChar>,
  _ payloadDescriptor: UnsafeMutablePointer<Int32>,
  _ metadataDescriptor: UnsafeMutablePointer<Int32>
) -> Int32

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
  private let lock = NSLock()
  private let temporaryRootDescriptor: Int32
  private let verifiedDirectoryDescriptor: Int32
  private let localDirectoryDescriptor: Int32
  private let directoryName: String
  private let fileName: String
  private let fileStatus: stat
  private var removed = false

  init(
    url: URL,
    metadata: CommittedExportMetadata,
    temporaryRootDescriptor: Int32,
    verifiedDirectoryDescriptor: Int32,
    localDirectoryDescriptor: Int32,
    directoryName: String,
    fileName: String,
    fileStatus: stat
  ) {
    self.url = url
    self.metadata = metadata
    self.temporaryRootDescriptor = temporaryRootDescriptor
    self.verifiedDirectoryDescriptor = verifiedDirectoryDescriptor
    self.localDirectoryDescriptor = localDirectoryDescriptor
    self.directoryName = directoryName
    self.fileName = fileName
    self.fileStatus = fileStatus
  }

  func isReadyForPicker() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !removed &&
      ExportArtifactPolicy.directoryIdentityMatches(
        parent: temporaryRootDescriptor,
        name: "verified_export_picker",
        opened: verifiedDirectoryDescriptor
      ) &&
      ExportArtifactPolicy.directoryIdentityMatches(
        parent: verifiedDirectoryDescriptor,
        name: directoryName,
        opened: localDirectoryDescriptor
      ) &&
      ExportArtifactPolicy.entryIdentityMatches(
        parent: localDirectoryDescriptor,
        name: fileName,
        expected: fileStatus
      )
  }

  func remove() {
    lock.lock()
    defer { lock.unlock() }
    if removed { return }
    removed = true
    let fileStillNamed = ExportArtifactPolicy.entryIdentityMatches(
      parent: localDirectoryDescriptor,
      name: fileName,
      expected: fileStatus
    )
    let directoryStillNamed = ExportArtifactPolicy.directoryIdentityMatches(
      parent: verifiedDirectoryDescriptor,
      name: directoryName,
      opened: localDirectoryDescriptor
    )
    if fileStillNamed {
      _ = unlinkat(localDirectoryDescriptor, fileName, 0)
    }
    Darwin.close(localDirectoryDescriptor)
    if directoryStillNamed {
      _ = unlinkat(verifiedDirectoryDescriptor, directoryName, AT_REMOVEDIR)
    }
    Darwin.close(verifiedDirectoryDescriptor)
    Darwin.close(temporaryRootDescriptor)
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
    guard source.path == sourcePath,
          let opened = openExportPair(
            documentsDirectory: documentsDirectory,
            sourcePath: source.path
          ) else {
      return nil
    }
    let payload = opened.payload
    let metadataHandle = opened.metadata
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
    var temporaryRootDescriptor = openDirectoryNoFollow(temporaryRoot.path)
    guard temporaryRootDescriptor >= 0 else {
      try? payload.close()
      return nil
    }
    var verifiedDirectoryDescriptor = openOrCreateDirectoryAt(
      parent: temporaryRootDescriptor,
      name: "verified_export_picker",
      exclusive: false
    )
    guard verifiedDirectoryDescriptor >= 0 else {
      try? payload.close()
      Darwin.close(temporaryRootDescriptor)
      return nil
    }
    let localDirectoryName = localDirectory.lastPathComponent
    var localDirectoryDescriptor = openOrCreateDirectoryAt(
      parent: verifiedDirectoryDescriptor,
      name: localDirectoryName,
      exclusive: true
    )
    guard localDirectoryDescriptor >= 0 else {
      try? payload.close()
      Darwin.close(verifiedDirectoryDescriptor)
      Darwin.close(temporaryRootDescriptor)
      return nil
    }
    defer {
      if localDirectoryDescriptor >= 0 {
        _ = unlinkat(localDirectoryDescriptor, metadata.fileName, 0)
        Darwin.close(localDirectoryDescriptor)
        _ = unlinkat(verifiedDirectoryDescriptor, localDirectoryName, AT_REMOVEDIR)
      }
      if verifiedDirectoryDescriptor >= 0 { Darwin.close(verifiedDirectoryDescriptor) }
      if temporaryRootDescriptor >= 0 { Darwin.close(temporaryRootDescriptor) }
      try? payload.close()
    }

    let outputDescriptor = openat(
      localDirectoryDescriptor,
      metadata.fileName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard outputDescriptor >= 0 else { return nil }
    var copyStatus = stat()
    guard fstat(outputDescriptor, &copyStatus) == 0,
          (copyStatus.st_mode & S_IFMT) == S_IFREG,
          copyStatus.st_nlink == 1 else {
      Darwin.close(outputDescriptor)
      return nil
    }
    let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
    guard copyAndValidate(payload, to: output, metadata: metadata) else { return nil }
    do {
      try output.synchronize()
      try output.close()
    } catch {
      return nil
    }
    guard entryIdentityMatches(
      parent: localDirectoryDescriptor,
      name: metadata.fileName,
      expected: copyStatus
    ),
      directoryIdentityMatches(
        parent: temporaryRootDescriptor,
        name: "verified_export_picker",
        opened: verifiedDirectoryDescriptor
      ),
      directoryIdentityMatches(
        parent: verifiedDirectoryDescriptor,
        name: localDirectoryName,
        opened: localDirectoryDescriptor
      ) else {
      return nil
    }
    try? payload.close()
    let pickerCopy = PickerExportCopy(
      url: localCopy,
      metadata: metadata,
      temporaryRootDescriptor: temporaryRootDescriptor,
      verifiedDirectoryDescriptor: verifiedDirectoryDescriptor,
      localDirectoryDescriptor: localDirectoryDescriptor,
      directoryName: localDirectoryName,
      fileName: metadata.fileName,
      fileStatus: copyStatus
    )
    temporaryRootDescriptor = -1
    verifiedDirectoryDescriptor = -1
    localDirectoryDescriptor = -1
    return pickerCopy.isReadyForPicker() ? pickerCopy : nil
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
          isCanonicalUtc(createdAt),
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

  private static func isCanonicalUtc(_ value: String) -> Bool {
    guard canonicalUtc.firstMatch(
      in: value,
      range: NSRange(value.startIndex..., in: value)
    ) != nil else {
      return false
    }
    let components = value.split(whereSeparator: { !$0.isNumber })
    guard components.count == 7,
          let year = Int(components[0]),
          let month = Int(components[1]),
          let day = Int(components[2]),
          let hour = Int(components[3]),
          let minute = Int(components[4]),
          let second = Int(components[5]),
          let fraction = Int(components[6]),
          components[6].count == 3 ||
            (components[6].count == 6 && !components[6].hasSuffix("000")) else {
      return false
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var requested = DateComponents()
    requested.calendar = calendar
    requested.timeZone = calendar.timeZone
    requested.year = year
    requested.month = month
    requested.day = day
    requested.hour = hour
    requested.minute = minute
    requested.second = second
    guard fraction >= 0 else { return false }
    guard let date = calendar.date(from: requested) else { return false }
    let actual = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: date
    )
    return actual.year == year && actual.month == month && actual.day == day &&
      actual.hour == hour && actual.minute == minute && actual.second == second
  }

  private static func openExportPair(
    documentsDirectory: URL,
    sourcePath: String
  ) -> (payload: FileHandle, metadata: FileHandle)? {
    var payloadDescriptor: Int32 = -1
    var metadataDescriptor: Int32 = -1
    let opened = documentsDirectory.path.withCString { root in
      sourcePath.withCString { source in
        attachmentCustodyOpenExportPair(
          root,
          source,
          &payloadDescriptor,
          &metadataDescriptor
        )
      }
    }
    guard opened == 1, payloadDescriptor >= 0, metadataDescriptor >= 0 else {
      if payloadDescriptor >= 0 { Darwin.close(payloadDescriptor) }
      if metadataDescriptor >= 0 { Darwin.close(metadataDescriptor) }
      return nil
    }
    return (
      FileHandle(fileDescriptor: payloadDescriptor, closeOnDealloc: true),
      FileHandle(fileDescriptor: metadataDescriptor, closeOnDealloc: true)
    )
  }

  static func openDirectoryNoFollow(_ path: String) -> Int32 {
    let descriptor = Darwin.open(
      path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { return -1 }
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
      Darwin.close(descriptor)
      return -1
    }
    return descriptor
  }

  static func openOrCreateDirectoryAt(
    parent: Int32,
    name: String,
    exclusive: Bool
  ) -> Int32 {
    var named = stat()
    if fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT, mkdirat(parent, name, S_IRWXU) == 0,
            fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
        return -1
      }
    } else if exclusive {
      return -1
    }
    guard (named.st_mode & S_IFMT) == S_IFDIR else { return -1 }
    let descriptor = openat(
      parent,
      name,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { return -1 }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
          (opened.st_mode & S_IFMT) == S_IFDIR,
          sameIdentity(named, opened) else {
      Darwin.close(descriptor)
      return -1
    }
    return descriptor
  }

  static func directoryIdentityMatches(
    parent: Int32,
    name: String,
    opened: Int32
  ) -> Bool {
    var namedStatus = stat()
    var openedStatus = stat()
    return fstatat(parent, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
      fstat(opened, &openedStatus) == 0 &&
      (namedStatus.st_mode & S_IFMT) == S_IFDIR &&
      (openedStatus.st_mode & S_IFMT) == S_IFDIR &&
      sameIdentity(namedStatus, openedStatus)
  }

  static func entryIdentityMatches(
    parent: Int32,
    name: String,
    expected: stat
  ) -> Bool {
    var named = stat()
    return fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
      (named.st_mode & S_IFMT) == S_IFREG && named.st_nlink == 1 &&
      sameIdentity(named, expected)
  }

  private static func sameIdentity(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
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
