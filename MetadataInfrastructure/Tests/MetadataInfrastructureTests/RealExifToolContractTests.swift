import Foundation
import Testing

@testable import MetadataInfrastructure

@Suite("Bundled ExifTool contract")
struct RealExifToolContractTests {
  @Test("reads the real Nikon NEF metadata contract")
  func realNikonRead() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let scriptPath = environment["RAWGEOSYNC_EXIFTOOL_PATH"],
      let nefPath = environment["RAWGEOSYNC_NEF_PATH"]
    else {
      return
    }
    let raw = try ReadOnlyRawFile(url: URL(fileURLWithPath: nefPath))
    let client = ExifToolClient(
      configuration: try .bundledPerl(scriptURL: URL(fileURLWithPath: scriptPath))
    )

    let metadata = try #require(try await client.readRawMetadata([raw]).first)
    #expect(metadata.dateTimeOriginal?.isEmpty == false)
    #expect(metadata.subsecondTimeOriginal?.isEmpty == false)
    #expect(metadata.offsetTimeOriginal == "+08:00")
    #expect(metadata.gps == nil)
    #expect(metadata.make == "NIKON CORPORATION")
    #expect(metadata.model == "NIKON Z 50")
    #expect(metadata.serialNumber?.isEmpty == false)
    #expect(metadata.shutterCount == 46_416)
    #expect(metadata.fileSize == 31_585_218)
    #expect(metadata.software == "Ver.02.50")
  }

  @Test("round-trips GPS and preserves unrelated XMP")
  func realExifToolRoundTrip() async throws {
    guard let scriptPath = ProcessInfo.processInfo.environment["RAWGEOSYNC_EXIFTOOL_PATH"] else {
      return
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RealExifToolContract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let xmpURL = directory.appendingPathComponent("sample.xmp")
    try Data(Self.fixtureXMP.utf8).write(to: xmpURL)
    let sidecar = try SidecarURL(validatedURL: xmpURL)
    let client = ExifToolClient(
      configuration: try .bundledPerl(scriptURL: URL(fileURLWithPath: scriptPath))
    )

    #expect(try await client.checkVersion() >= ExifToolVersion("13.59"))
    let before = try await client.readSidecarMetadata(at: sidecar)
    #expect(before.documentID == "xmp.did:test-document")
    #expect(before.originalDocumentID == "xmp.did:test-original")
    #expect(before.software == "Lightroom Classic")
    let gps = try GPSMetadata(latitude: -22.987_654, longitude: 113.123_456, altitude: -10.5)
    try await client.writeGPS(gps, to: sidecar)
    let after = try await client.readSidecarMetadata(at: sidecar)

    #expect(after.gps?.isEquivalent(to: gps) == true)
    #expect(after.nonGPSSemanticDigest == before.nonGPSSemanticDigest)
    #expect(after.documentID == before.documentID)
    #expect(after.originalDocumentID == before.originalDocumentID)
    #expect(after.xmpToolkit?.contains("ExifTool 13.59") == true)
    let text = try String(contentsOf: xmpURL, encoding: .utf8)
    #expect(text.contains("Exposure2012"))
    #expect(text.contains("0.50"))
  }

  private static let fixtureXMP = """
    <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
          xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
          crs:Exposure2012="0.50"
          xmpMM:DocumentID="xmp.did:test-document"
          xmpMM:OriginalDocumentID="xmp.did:test-original"
          tiff:Software="Lightroom Classic"/>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
}
