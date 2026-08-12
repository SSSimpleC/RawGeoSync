import Foundation
import Testing

@testable import MetadataInfrastructure

@Suite("Lightroom Catalog bridge manifest")
struct CatalogBridgeManifestTests {
  @Test("Swift and Lua share one canonical golden manifest")
  func sharedGoldenManifest() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/RawGeoSync.locations.jsonl")
    let manifest = try CatalogBridgeManifestStore().read(from: fixtureURL)
    #expect(manifest.header.schemaVersion == .current)
    #expect(manifest.header.recordCount == 1)
    #expect(manifest.assets.first?.relativePath == "Z50/SYNTHETIC.NEF")
    #expect(
      manifest.payloadSHA256 == "e0bb190c8dcf30f186b91028fe6e823f4adac4d98a1c0eb8f175922cc3df1b54")
  }

  @Test("exports one atomic manifest and repeated semantic output is a no-op")
  func exportAndIdempotency() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try fixture.store.export(fixture.request(paths: ["Z50/照片 1.NEF"]))
    #expect(first.disposition == .created)
    #expect(first.recordCount == 1)
    #expect(first.manifest.header.existingGPSPolicy == "overwrite")
    #expect(first.manifest.header.skippedCount == 2)
    #expect(first.manifest.assets[0].recordDigestSHA256?.count == 64)
    let attributes = try FileManager.default.attributesOfItem(atPath: first.artifactURL.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    let modificationDate = try #require(attributes[.modificationDate] as? Date)

    let second = try fixture.store.export(fixture.request(paths: ["Z50/照片 1.NEF"]))
    #expect(second.disposition == .unchanged)
    #expect(second.manifest.header.manifestID == first.manifest.header.manifestID)
    #expect(second.manifest.header.revision == first.manifest.header.revision)
    let secondAttributes = try FileManager.default.attributesOfItem(atPath: second.artifactURL.path)
    #expect(secondAttributes[.modificationDate] as? Date == modificationDate)
  }

  @Test("replaces a valid older manifest and preserves activity history")
  func revisionHistory() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try fixture.store.export(fixture.request(paths: ["Z50/照片 1.NEF"]))
    let second = try fixture.store.export(
      fixture.request(paths: ["Z50/照片 1.NEF", "Z5/照片 2.NEF"])
    )
    #expect(second.disposition == .replaced)
    #expect(second.manifest.header.activityID == first.manifest.header.activityID)
    #expect(second.manifest.header.revision == 2)
    #expect(second.manifest.header.priorPayloadSHA256 == first.manifest.payloadSHA256)
    #expect(second.recordCount == 2)
  }

  @Test("rejects unsafe paths, duplicates, changed source identity and symlinks")
  func pathAndIdentityProtection() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(throws: CatalogBridgeManifestError.self) {
      try fixture.store.export(fixture.request(paths: ["../逃逸.NEF"]))
    }

    let record = try fixture.record(path: "Z50/照片 1.NEF")
    let duplicateRequest = CatalogBridgeExportRequest(
      rootDirectoryURL: fixture.root,
      assets: [record, record],
      appVersion: "test",
      algorithmVersion: "test"
    )
    #expect(throws: CatalogBridgeManifestError.self) {
      try fixture.store.export(duplicateRequest)
    }

    let changedIdentity = CatalogBridgeAssetRecord(
      recordID: record.recordID,
      relativePath: record.relativePath,
      assetKind: record.assetKind,
      fileIdentity: CatalogBridgeFileIdentity(
        byteCount: record.fileIdentity.byteCount + 1,
        exifDateTimeOriginal: record.fileIdentity.exifDateTimeOriginal
      ),
      correctedCaptureTimeUTC: record.correctedCaptureTimeUTC,
      location: record.location,
      decision: record.decision
    )
    #expect(throws: CatalogBridgeManifestError.self) {
      try fixture.store.export(
        CatalogBridgeExportRequest(
          rootDirectoryURL: fixture.root,
          assets: [changedIdentity],
          appVersion: "test",
          algorithmVersion: "test"
        )
      )
    }
  }

  @Test("detects truncation, CRLF, record damage and damaged existing target")
  func integrityProtection() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let result = try fixture.store.export(fixture.request(paths: ["Z50/照片 1.NEF"]))
    let original = try Data(contentsOf: result.artifactURL)

    try original.dropLast().write(to: result.artifactURL)
    #expect(throws: CatalogBridgeManifestError.self) {
      try fixture.store.read(from: result.artifactURL)
    }
    #expect(throws: CatalogBridgeManifestError.self) {
      try fixture.store.export(fixture.request(paths: ["Z50/照片 1.NEF"]))
    }

    var crlf = original
    crlf.insert(0x0D, at: crlf.firstIndex(of: 0x0A)!)
    let crlfURL = fixture.root.appendingPathComponent("crlf.jsonl")
    try crlf.write(to: crlfURL)
    #expect(throws: CatalogBridgeManifestError.self) {
      try fixture.store.read(from: crlfURL)
    }
  }

  @Test("handles ten thousand records with deterministic order")
  func largeManifest() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let base = try fixture.record(path: "Z50/照片 1.NEF")
    let assets = (0..<10_000).map { index in
      CatalogBridgeAssetRecord(
        recordID: UUID(),
        relativePath: String(format: "Synthetic/%05d.NEF", index),
        fileIdentity: base.fileIdentity,
        correctedCaptureTimeUTC: base.correctedCaptureTimeUTC,
        location: base.location,
        decision: base.decision
      )
    }
    let target = fixture.root.appendingPathComponent("large.jsonl")
    let header = CatalogBridgeManifestHeader(
      appVersion: "test",
      algorithmVersion: "test",
      recordCount: assets.count,
      rootDisplayName: "fixture"
    )
    let started = ContinuousClock.now
    _ = try fixture.store.write(header: header, assets: assets.reversed(), to: target)
    let elapsed = ContinuousClock.now - started
    let decoded = try fixture.store.read(from: target)
    #expect(decoded.assets.count == 10_000)
    #expect(decoded.assets.first?.relativePath == "Synthetic/00000.NEF")
    #expect(decoded.assets.last?.relativePath == "Synthetic/09999.NEF")
    #expect(elapsed < .seconds(5))
  }

  @Test("exports ten thousand real paths without reading RAW contents")
  func largeExport() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let directory = fixture.root.appendingPathComponent("Synthetic", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = fixture.root.appendingPathComponent("Z50/照片 1.NEF")
    let base = try fixture.record(path: "Z50/照片 1.NEF")
    var assets: [CatalogBridgeAssetRecord] = []
    assets.reserveCapacity(10_000)
    for index in 0..<10_000 {
      let relativePath = String(format: "Synthetic/%05d.NEF", index)
      try FileManager.default.linkItem(
        at: source,
        to: fixture.root.appendingPathComponent(relativePath)
      )
      assets.append(
        CatalogBridgeAssetRecord(
          recordID: try CatalogBridgeManifestStore.stableRecordID(
            relativePath: relativePath,
            fileIdentity: base.fileIdentity
          ),
          relativePath: relativePath,
          fileIdentity: base.fileIdentity,
          correctedCaptureTimeUTC: base.correctedCaptureTimeUTC,
          location: base.location,
          decision: base.decision
        )
      )
    }
    let request = CatalogBridgeExportRequest(
      rootDirectoryURL: fixture.root,
      assets: assets,
      appVersion: "test",
      algorithmVersion: "test"
    )
    let started = ContinuousClock.now
    let result = try fixture.store.export(request)
    let elapsed = ContinuousClock.now - started
    #expect(result.recordCount == 10_000)
    // Keep the 3-second engineering target locally. Shared GitHub runners have
    // substantially noisier filesystem scheduling, so CI uses a regression
    // ceiling that still catches material slowdowns without becoming flaky.
    let performanceLimit: Duration =
      ProcessInfo.processInfo.environment["CI"] == "true" ? .seconds(5) : .seconds(3)
    #expect(elapsed < performanceLimit)
  }
}

private final class Fixture {
  let root: URL
  let store = CatalogBridgeManifestStore()

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CatalogBridgeTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Z50", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Z5", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("raw-one".utf8).write(to: root.appendingPathComponent("Z50/照片 1.NEF"))
    try Data("raw-two".utf8).write(to: root.appendingPathComponent("Z5/照片 2.NEF"))
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func request(paths: [String]) throws -> CatalogBridgeExportRequest {
    CatalogBridgeExportRequest(
      rootDirectoryURL: root,
      assets: try paths.map(record(path:)),
      appVersion: "0.3.0-test",
      algorithmVersion: "2.0-test",
      skippedCount: 2,
      writeAltitude: false
    )
  }

  func record(path: String) throws -> CatalogBridgeAssetRecord {
    let url = root.appendingPathComponent(path)
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 1
    let identity = CatalogBridgeFileIdentity(
      byteCount: size,
      exifDateTimeOriginal: "2030:01:02 03:04:05",
      subsecondTimeOriginal: "12",
      offsetTimeOriginal: "+08:00",
      make: "Example",
      model: "Camera",
      serialNumber: "fixture",
      shutterCount: 10
    )
    return CatalogBridgeAssetRecord(
      recordID: try CatalogBridgeManifestStore.stableRecordID(
        relativePath: path,
        fileIdentity: identity
      ),
      relativePath: path,
      fileIdentity: identity,
      correctedCaptureTimeUTC: Date(timeIntervalSince1970: 1_893_456_000),
      location: try GPSMetadata(latitude: 12.25, longitude: 34.5),
      decision: CatalogBridgeDecision(
        confidence: "reliable",
        method: "interpolatedTrack",
        granularity: "track",
        verification: .automatic,
        ruleVersion: "test"
      )
    )
  }
}
