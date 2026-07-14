import CryptoKit
import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  private var root: URL!
  private var documents: URL!
  private var temporary: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("export-policy-tests-\(UUID().uuidString)", isDirectory: true)
    documents = root.appendingPathComponent("Documents", isDirectory: true)
    temporary = root.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(
      at: documents,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: temporary,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testCommittedArtifactCreatesVerifiedCallLocalPickerCopy() throws {
    let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
    let report = try committedReport(bytes: bytes)
    let pickerCopy = ExportArtifactPolicy.makePickerCopy(
      sourcePath: report.path,
      suggestedName: report.lastPathComponent,
      mimeType: "application/pdf",
      documentsDirectory: documents,
      temporaryRoot: temporary
    )

    XCTAssertNotNil(pickerCopy)
    XCTAssertEqual(try Data(contentsOf: pickerCopy!.url), bytes)
    XCTAssertTrue(pickerCopy!.url.path.hasPrefix(temporary.path + "/"))

    try FileManager.default.removeItem(at: report)
    try Data(repeating: 9, count: bytes.count).write(to: report)
    XCTAssertEqual(try Data(contentsOf: pickerCopy!.url), bytes)

    let copyURL = pickerCopy!.url
    pickerCopy!.remove()
    XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
  }

  func testGeometryMetadataAndChecksumMismatchesFailClosed() throws {
    let report = try committedReport(bytes: Data([1, 2, 3]))
    XCTAssertNil(
      ExportArtifactPolicy.makePickerCopy(
        sourcePath: report.path,
        suggestedName: "other.pdf",
        mimeType: "application/pdf",
        documentsDirectory: documents,
        temporaryRoot: temporary
      )
    )
    XCTAssertNil(
      ExportArtifactPolicy.makePickerCopy(
        sourcePath: report.path,
        suggestedName: report.lastPathComponent,
        mimeType: "application/zip",
        documentsDirectory: documents,
        temporaryRoot: temporary
      )
    )

    try Data([9, 9, 9]).write(to: report)
    XCTAssertNil(
      ExportArtifactPolicy.makePickerCopy(
        sourcePath: report.path,
        suggestedName: report.lastPathComponent,
        mimeType: "application/pdf",
        documentsDirectory: documents,
        temporaryRoot: temporary
      )
    )

  }

  func testSymlinkAndIncompleteMetadataFailClosed() throws {
    let report = try committedReport(bytes: Data([1, 2, 3]))
    let link = report.deletingLastPathComponent().appendingPathComponent("report-link.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: report)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: report.path + ".json"),
      to: URL(fileURLWithPath: link.path + ".json")
    )
    XCTAssertNil(
      ExportArtifactPolicy.makePickerCopy(
        sourcePath: link.path,
        suggestedName: link.lastPathComponent,
        mimeType: "application/pdf",
        documentsDirectory: documents,
        temporaryRoot: temporary
      )
    )

    let metadataURL = URL(fileURLWithPath: report.path + ".json")
    var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))
      as! [String: Any]
    metadata["state"] = "partial"
    try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
    XCTAssertNil(
      ExportArtifactPolicy.makePickerCopy(
        sourcePath: report.path,
        suggestedName: report.lastPathComponent,
        mimeType: "application/pdf",
        documentsDirectory: documents,
        temporaryRoot: temporary
      )
    )

    metadata["state"] = "complete"
    metadata["created_at"] = 7
    try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
    XCTAssertNil(
      ExportArtifactPolicy.makePickerCopy(
        sourcePath: report.path,
        suggestedName: report.lastPathComponent,
        mimeType: "application/pdf",
        documentsDirectory: documents,
        temporaryRoot: temporary
      )
    )

    metadata["created_at"] = "2026-07-14T09:00:00.000Z"
    metadata["warnings"] = "none"
    try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
    XCTAssertNil(
      ExportArtifactPolicy.makePickerCopy(
        sourcePath: report.path,
        suggestedName: report.lastPathComponent,
        mimeType: "application/pdf",
        documentsDirectory: documents,
        temporaryRoot: temporary
      )
    )
  }

  private func committedReport(bytes: Data) throws -> URL {
    let subjectId = "artwork-1"
    let subjectHash = SHA256.hash(data: Data(subjectId.utf8)).hex
    let artifactId = "report-\(subjectHash.prefix(24))-1"
    let directory = documents
      .appendingPathComponent("generated_exports/reports", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let report = directory.appendingPathComponent("\(artifactId).pdf")
    try bytes.write(to: report)
    let metadata: [String: Any] = [
      "metadata_version": 1,
      "state": "complete",
      "artifact_id": artifactId,
      "kind": "report",
      "subject_id": subjectId,
      "file_name": report.lastPathComponent,
      "mime_type": "application/pdf",
      "byte_size": bytes.count,
      "checksum_sha256": SHA256.hash(data: bytes).hex,
      "created_at": "2026-07-14T09:00:00.000Z",
      "warnings": [],
    ]
    try JSONSerialization.data(withJSONObject: metadata)
      .write(to: URL(fileURLWithPath: report.path + ".json"))
    return report
  }
}

private extension Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
