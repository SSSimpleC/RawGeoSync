import Foundation
import Testing

@testable import MetadataInfrastructure

private struct FixtureSidecar: Codable {
  var gps: GPSMetadata?
  var semantic: String
}

private enum FakeToolError: Error {
  case injectedWriteFailure
}

private actor FakeMetadataTool: MetadataTooling {
  var rawGPS: [URL: GPSMetadata] = [:]
  var failOnWriteNumber: Int?
  var cancelOnWriteNumber: Int?
  var changeSemanticOnWrite = false
  private var writeCount = 0

  init(
    failOnWriteNumber: Int? = nil,
    cancelOnWriteNumber: Int? = nil,
    changeSemanticOnWrite: Bool = false
  ) {
    self.failOnWriteNumber = failOnWriteNumber
    self.cancelOnWriteNumber = cancelOnWriteNumber
    self.changeSemanticOnWrite = changeSemanticOnWrite
  }

  func checkVersion() async throws -> ExifToolVersion {
    try ExifToolVersion("13.59")
  }

  func readRawMetadata(_ files: [ReadOnlyRawFile]) async throws -> [RawPhotoMetadata] {
    files.map {
      RawPhotoMetadata(
        rawFile: $0,
        dateTimeOriginal: "2026:08:08 14:14:00",
        subsecondTimeOriginal: "00",
        offsetTimeOriginal: "+08:00",
        gps: rawGPS[$0.url]
      )
    }
  }

  func readSidecarMetadata(at sidecar: SidecarURL) async throws -> SidecarMetadata {
    let fixture = try JSONDecoder().decode(
      FixtureSidecar.self,
      from: Data(contentsOf: sidecar.url)
    )
    return SidecarMetadata(gps: fixture.gps, nonGPSSemanticDigest: fixture.semantic)
  }

  func writeGPS(_ gps: GPSMetadata, to sidecar: SidecarURL) async throws {
    writeCount += 1
    if writeCount == cancelOnWriteNumber { throw MetadataInfrastructureError.cancelled }
    if writeCount == failOnWriteNumber { throw FakeToolError.injectedWriteFailure }
    let existing = try? JSONDecoder().decode(
      FixtureSidecar.self,
      from: Data(contentsOf: sidecar.url)
    )
    let semantic = changeSemanticOnWrite ? "unexpected-change" : (existing?.semantic ?? "minimal")
    try JSONEncoder().encode(FixtureSidecar(gps: gps, semantic: semantic)).write(to: sidecar.url)
  }
}

@Suite("XMP transaction coordinator")
struct XMPTransactionTests {
  @Test("creates sidecar, is idempotent, never changes RAW, and undoes")
  func createIdempotentAndUndo() async throws {
    let context = try FixtureContext(rawNames: ["DSC_0001.NEF"])
    defer { context.remove() }
    let tool = FakeMetadataTool()
    let coordinator = XMPTransactionCoordinator(metadataTool: tool, backupRoot: context.backupRoot)
    let gps = try GPSMetadata(latitude: 22.987_654, longitude: 113.123_456, altitude: 10)
    let request = SidecarWriteRequest(rawFile: context.rawFiles[0], gps: gps)
    let originalRaw = try Data(contentsOf: context.rawFiles[0].url)

    let plan = try await coordinator.makeWritePlan([request])
    #expect(plan.items[0].disposition == .create)
    let report = try await coordinator.apply(plan)
    #expect(report.appliedCount == 1)
    let sidecar = try SidecarURL(for: context.rawFiles[0])
    #expect(FileManager.default.fileExists(atPath: sidecar.url.path))
    #expect(try Data(contentsOf: context.rawFiles[0].url) == originalRaw)

    let beforeSecondPlan = try FileFingerprint.capture(sidecar.url, includeDigest: true)
    let secondPlan = try await coordinator.makeWritePlan([request])
    #expect(secondPlan.items[0].disposition == .alreadyApplied)
    let secondReport = try await coordinator.apply(secondPlan)
    #expect(secondReport.appliedCount == 0)
    #expect(try FileFingerprint.capture(sidecar.url, includeDigest: true) == beforeSecondPlan)

    try await coordinator.undo(transactionID: report.transactionID)
    #expect(!FileManager.default.fileExists(atPath: sidecar.url.path))
    #expect(try await coordinator.manifest(transactionID: report.transactionID).status == .undone)
  }

  @Test("existing different GPS conflicts unless replacement is explicit")
  func existingGPSConflictAndReplacement() async throws {
    let context = try FixtureContext(rawNames: ["DSC_0002.NEF"])
    defer { context.remove() }
    let raw = context.rawFiles[0]
    let sidecar = try SidecarURL(for: raw)
    let oldGPS = try GPSMetadata(latitude: 20, longitude: 110)
    let newGPS = try GPSMetadata(latitude: 22, longitude: 113)
    let original = try JSONEncoder().encode(FixtureSidecar(gps: oldGPS, semantic: "lightroom-edit"))
    try original.write(to: sidecar.url)
    let tool = FakeMetadataTool()
    let coordinator = XMPTransactionCoordinator(metadataTool: tool, backupRoot: context.backupRoot)

    let conflict = try await coordinator.makeWritePlan([
      SidecarWriteRequest(rawFile: raw, gps: newGPS)
    ])
    guard case .conflict = conflict.items[0].disposition else {
      Issue.record("应报告已有 GPS 冲突")
      return
    }

    let replace = try await coordinator.makeWritePlan([
      SidecarWriteRequest(rawFile: raw, gps: newGPS, existingGPSPolicy: .replace)
    ])
    #expect(replace.items[0].disposition == .update)
    let report = try await coordinator.apply(replace)
    let updated = try await tool.readSidecarMetadata(at: sidecar)
    #expect(updated.gps == newGPS)
    #expect(updated.nonGPSSemanticDigest == "lightroom-edit")

    try await coordinator.undo(transactionID: report.transactionID)
    #expect(try Data(contentsOf: sidecar.url) == original)
  }

  @Test("precondition changes abort before touching the new sidecar")
  func detectsPreconditionChange() async throws {
    let context = try FixtureContext(rawNames: ["DSC_0003.NEF"])
    defer { context.remove() }
    let raw = context.rawFiles[0]
    let sidecar = try SidecarURL(for: raw)
    let tool = FakeMetadataTool()
    let coordinator = XMPTransactionCoordinator(metadataTool: tool, backupRoot: context.backupRoot)
    let request = SidecarWriteRequest(
      rawFile: raw,
      gps: try GPSMetadata(latitude: 22, longitude: 113)
    )
    let plan = try await coordinator.makeWritePlan([request])
    let external = try JSONEncoder().encode(FixtureSidecar(gps: nil, semantic: "external"))
    try external.write(to: sidecar.url)

    let report = try await coordinator.apply(plan)
    #expect(report.failedCount == 1)
    #expect(try Data(contentsOf: sidecar.url) == external)
    #expect(try await coordinator.manifest(transactionID: plan.id).status == .completedWithFailures)
  }

  @Test("RAW SHA-256 detects content changes even when file size is unchanged")
  func rawDigestPrecondition() async throws {
    let context = try FixtureContext(rawNames: ["DSC_0012.NEF"])
    defer { context.remove() }
    let raw = context.rawFiles[0]
    let tool = FakeMetadataTool()
    let coordinator = XMPTransactionCoordinator(metadataTool: tool, backupRoot: context.backupRoot)
    let plan = try await coordinator.makeWritePlan([
      SidecarWriteRequest(rawFile: raw, gps: try GPSMetadata(latitude: 22, longitude: 113))
    ])
    #expect(plan.items[0].rawPrecondition.sha256 != nil)
    let originalSize = plan.items[0].rawPrecondition.byteCount
    try Data(repeating: 0x58, count: originalSize).write(to: raw.url)

    let report = try await coordinator.apply(plan)
    #expect(report.failedCount == 1)
    #expect(!FileManager.default.fileExists(atPath: try SidecarURL(for: raw).url.path))
  }

  @Test("one failure preserves prior successes and continues remaining files")
  func batchFailureContinues() async throws {
    let context = try FixtureContext(rawNames: ["DSC_0004.NEF", "DSC_0005.NEF", "DSC_0008.NEF"])
    defer { context.remove() }
    let tool = FakeMetadataTool(failOnWriteNumber: 2)
    let coordinator = XMPTransactionCoordinator(metadataTool: tool, backupRoot: context.backupRoot)
    let gps = try GPSMetadata(latitude: 22, longitude: 113)
    let plan = try await coordinator.makeWritePlan(
      context.rawFiles.map { SidecarWriteRequest(rawFile: $0, gps: gps) }
    )

    let report = try await coordinator.apply(plan)
    #expect(report.appliedCount == 2)
    #expect(report.failedCount == 1)
    #expect(report.wasCancelled == false)
    for (index, raw) in context.rawFiles.enumerated() {
      let sidecar = try SidecarURL(for: raw)
      #expect(FileManager.default.fileExists(atPath: sidecar.url.path) == (index != 1))
    }
    #expect(try await coordinator.manifest(transactionID: plan.id).status == .completedWithFailures)

    try await coordinator.undo(transactionID: report.transactionID)
    for raw in context.rawFiles {
      let sidecar = try SidecarURL(for: raw)
      #expect(!FileManager.default.fileExists(atPath: sidecar.url.path))
    }
  }

  @Test("semantic drift fails safely and leaves the original byte-for-byte intact")
  func semanticDriftRollsBack() async throws {
    let context = try FixtureContext(rawNames: ["DSC_0006.NEF"])
    defer { context.remove() }
    let raw = context.rawFiles[0]
    let sidecar = try SidecarURL(for: raw)
    let oldGPS = try GPSMetadata(latitude: 20, longitude: 110)
    let original = try JSONEncoder().encode(FixtureSidecar(gps: oldGPS, semantic: "keep-me"))
    try original.write(to: sidecar.url)
    let tool = FakeMetadataTool(changeSemanticOnWrite: true)
    let coordinator = XMPTransactionCoordinator(metadataTool: tool, backupRoot: context.backupRoot)
    let plan = try await coordinator.makeWritePlan([
      SidecarWriteRequest(
        rawFile: raw,
        gps: try GPSMetadata(latitude: 22, longitude: 113),
        existingGPSPolicy: .replace
      )
    ])

    let report = try await coordinator.apply(plan)
    #expect(report.failedCount == 1)
    #expect(try Data(contentsOf: sidecar.url) == original)
  }

  @Test("cancellation keeps completed files and leaves remaining files pending")
  func cancellationKeepsSuccesses() async throws {
    let context = try FixtureContext(rawNames: ["DSC_0009.NEF", "DSC_0010.NEF", "DSC_0011.NEF"])
    defer { context.remove() }
    let tool = FakeMetadataTool(cancelOnWriteNumber: 2)
    let coordinator = XMPTransactionCoordinator(metadataTool: tool, backupRoot: context.backupRoot)
    let gps = try GPSMetadata(latitude: 22, longitude: 113)
    let plan = try await coordinator.makeWritePlan(
      context.rawFiles.map { SidecarWriteRequest(rawFile: $0, gps: gps) }
    )

    let report = try await coordinator.apply(plan)
    #expect(report.appliedCount == 1)
    #expect(report.failedCount == 1)
    #expect(report.wasCancelled)
    #expect(try await coordinator.manifest(transactionID: plan.id).status == .cancelled)
    for (index, raw) in context.rawFiles.enumerated() {
      let sidecar = try SidecarURL(for: raw)
      #expect(FileManager.default.fileExists(atPath: sidecar.url.path) == (index == 0))
    }

    try await coordinator.undo(transactionID: report.transactionID)
    #expect(
      !FileManager.default.fileExists(atPath: try SidecarURL(for: context.rawFiles[0]).url.path))
  }

  @Test("undo refuses to overwrite a sidecar changed after the transaction")
  func undoConflict() async throws {
    let context = try FixtureContext(rawNames: ["DSC_0007.NEF"])
    defer { context.remove() }
    let tool = FakeMetadataTool()
    let coordinator = XMPTransactionCoordinator(metadataTool: tool, backupRoot: context.backupRoot)
    let plan = try await coordinator.makeWritePlan([
      SidecarWriteRequest(
        rawFile: context.rawFiles[0],
        gps: try GPSMetadata(latitude: 22, longitude: 113)
      )
    ])
    let report = try await coordinator.apply(plan)
    let sidecar = try SidecarURL(for: context.rawFiles[0])
    try Data("Lightroom changed this".utf8).write(to: sidecar.url)

    await #expect(
      throws: MetadataInfrastructureError.transactionCannotBeUndone(report.transactionID)
    ) {
      try await coordinator.undo(transactionID: report.transactionID)
    }
    #expect(try Data(contentsOf: sidecar.url) == Data("Lightroom changed this".utf8))
  }

  @Test("cleanup retains only the latest ten batches younger than thirty days")
  func backupRetention() async throws {
    let context = try FixtureContext(rawNames: [])
    defer { context.remove() }
    let coordinator = XMPTransactionCoordinator(
      metadataTool: FakeMetadataTool(),
      backupRoot: context.backupRoot
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var recentIDs: [UUID] = []
    for hour in 0..<11 {
      let plan = SidecarWritePlan(
        createdAt: now.addingTimeInterval(TimeInterval(-hour * 3_600)),
        items: []
      )
      recentIDs.append(plan.id)
      _ = try await coordinator.apply(plan)
    }
    let oldPlan = SidecarWritePlan(
      createdAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
      items: []
    )
    _ = try await coordinator.apply(oldPlan)

    let report = try await coordinator.cleanupBackups(now: now)
    #expect(Set(report.removedTransactionIDs) == Set([recentIDs[10], oldPlan.id]))
    #expect(report.retainedTransactionIDs.count == 10)
    #expect(try await coordinator.transactionIDs().count == 10)
  }
}

private struct FixtureContext {
  let root: URL
  let backupRoot: URL
  let rawFiles: [ReadOnlyRawFile]

  init(rawNames: [String]) throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("XMPTransactionTests-\(UUID().uuidString)", isDirectory: true)
    root = rootURL
    backupRoot = rootURL.appendingPathComponent("backups", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    rawFiles = try rawNames.map { name in
      let url = rootURL.appendingPathComponent(name)
      try Data("immutable raw \(name)".utf8).write(to: url)
      return try ReadOnlyRawFile(url: url)
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
