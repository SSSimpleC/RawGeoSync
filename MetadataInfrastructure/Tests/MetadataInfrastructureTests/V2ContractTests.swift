import Foundation
import Testing

@testable import MetadataInfrastructure

@Suite("Metadata and transaction v2 contract")
struct V2ContractTests {
  @Test("DNG JPEG and TIFF are scan-only and cannot become proprietary RAW targets")
  func scanOnlyMediaBoundary() throws {
    let directory = try v2TemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let specifications: [(String, ReadOnlyMediaKind)] = [
      ("sample.NEF", .proprietaryRaw),
      ("sample.DNG", .dng),
      ("sample.JPG", .jpeg),
      ("sample.TIFF", .tiff),
    ]
    for (name, expectedKind) in specifications {
      let url = directory.appendingPathComponent(name)
      try Data("fixture".utf8).write(to: url)
      let media = try ReadOnlyMediaFile(url: url)
      #expect(media.kind == expectedKind)
      if expectedKind == .proprietaryRaw {
        let raw = try ReadOnlyRawFile(mediaFile: media)
        #expect(try SidecarURL(for: raw).url.pathExtension == "xmp")
      } else {
        #expect(throws: MetadataInfrastructureError.self) {
          try ReadOnlyRawFile(mediaFile: media)
        }
      }
    }
  }

  @Test("existing sidecar lookup is case insensitive")
  func existingSidecarLookup() throws {
    let directory = try v2TemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rawURL = directory.appendingPathComponent("sample.NEF")
    try Data("raw".utf8).write(to: rawURL)
    let raw = try ReadOnlyRawFile(url: rawURL)
    let uppercase = directory.appendingPathComponent("sample.XMP")
    try Data("xmp".utf8).write(to: uppercase)

    #expect(try SidecarURL.existing(for: raw)?.url == uppercase)
  }

  @Test("provenance strength is deterministic and strictly ordered")
  func provenanceStrength() {
    let automaticExact = provenance(source: .exactTrackPoint, verification: .automatic)
    let confirmedNearest = provenance(source: .nearestTrackPoint, verification: .userConfirmed)
    let manual = provenance(source: .manual, verification: .manual)
    let accurate = provenance(
      source: .interpolatedTrack,
      verification: .automatic,
      horizontalAccuracy: 5
    )
    let inaccurate = provenance(
      source: .interpolatedTrack,
      verification: .automatic,
      horizontalAccuracy: 50
    )

    #expect(confirmedNearest.isProvablyStronger(than: automaticExact))
    #expect(manual.isProvablyStronger(than: confirmedNearest))
    #expect(accurate.isProvablyStronger(than: inaccurate))
    #expect(!automaticExact.isProvablyStronger(than: automaticExact))
  }

  @Test("schema v2 encodes explicitly and a schema-less v1 manifest still decodes")
  func manifestSchemaCompatibility() throws {
    let directory = try v2TemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rawURL = directory.appendingPathComponent("schema.NEF")
    try Data("raw".utf8).write(to: rawURL)
    let raw = try ReadOnlyRawFile(url: rawURL)
    let item = SidecarWritePlanItem(
      rawFile: raw,
      sidecar: try SidecarURL(for: raw),
      desiredGPS: try GPSMetadata(latitude: 22, longitude: 113),
      disposition: .create,
      rawPrecondition: FileFingerprint(byteCount: 3, modificationTime: .distantPast, sha256: "raw"),
      sidecarPrecondition: nil,
      originalNonGPSSemanticDigest: nil,
      matchProvenance: provenance(source: .exactTrackPoint, verification: .automatic)
    )
    let plan = SidecarWritePlan(items: [item])
    let manifest = XMPTransactionManifest(plan: plan)
    let encoder = JSONEncoder()
    let v2Data = try encoder.encode(manifest)
    let v2Object = try #require(
      try JSONSerialization.jsonObject(with: v2Data) as? [String: Any]
    )
    #expect(v2Object["schemaVersion"] as? Int == 2)

    var v1Object = v2Object
    v1Object.removeValue(forKey: "schemaVersion")
    if var records = v1Object["records"] as? [[String: Any]],
      var record = records.first,
      var planItem = record["planItem"] as? [String: Any]
    {
      for key in [
        "matchProvenance", "existingGPS", "existingGPSOrigin", "existingMatchProvenance",
        "provenanceTransactionID",
      ] {
        planItem.removeValue(forKey: key)
      }
      record["planItem"] = planItem
      records[0] = record
      v1Object["records"] = records
    }
    let v1Data = try JSONSerialization.data(withJSONObject: v1Object)
    let decoded = try JSONDecoder().decode(XMPTransactionManifest.self, from: v1Data)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.records.first?.planItem.matchProvenance == nil)

    let reencoded =
      try JSONSerialization.jsonObject(with: encoder.encode(decoded)) as? [String: Any]
    #expect(reencoded?["schemaVersion"] as? Int == 2)
  }
}

private func provenance(
  source: MatchProvenanceSource,
  verification: MatchProvenanceVerification,
  horizontalAccuracy: Double? = nil
) -> MatchProvenance {
  MatchProvenance(
    source: source,
    verification: verification,
    algorithmVersion: "test-v2",
    trackFileSHA256: String(repeating: "a", count: 64),
    generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
    horizontalAccuracyMeters: horizontalAccuracy
  )
}

private func v2TemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("MetadataV2Tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
