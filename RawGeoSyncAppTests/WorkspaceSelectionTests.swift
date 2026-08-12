import XCTest

@testable import RawGeoSync

@MainActor
final class WorkspaceSelectionTests: XCTestCase {
  func testCatalogBridgeIsTheDefaultOutput() {
    XCTAssertEqual(SourceConfiguration().outputMode, .lightroomCatalogBridge)
    XCTAssertEqual(OutputMode.allCases, [.lightroomCatalogBridge, .xmpSidecar])
  }

  func testCatalogBridgeDoesNotLetExternalXMPSuppressManifestExport() {
    let workspace = WorkspaceViewModel(service: DemoGeoWorkflowService())
    var match = makeMatch(id: "external-xmp", confidence: .reliable)
    match.isSelectedForWrite = true
    match.hasProtectedExternalXMP = true
    workspace.matches = [match]

    workspace.configuration.outputMode = .lightroomCatalogBridge
    XCTAssertEqual(workspace.writableCount, 1)

    workspace.configuration.outputMode = .xmpSidecar
    XCTAssertEqual(workspace.writableCount, 0)
  }

  func testLiveBridgeExportsOneManifestWithoutXMP() async throws {
    let fixture = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let rawURL = fixture.appendingPathComponent("Z50/DSC_0001.NEF")
    try FileManager.default.createDirectory(
      at: rawURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data([0x4E, 0x45, 0x46, 0x00]).write(to: rawURL)
    var match = makeMatch(id: rawURL.path, confidence: .reliable)
    match.fileURL = rawURL
    match.identity = PhotoIdentity(
      relativePath: "Z50/DSC_0001.NEF",
      fileSize: 4,
      exifDateTimeOriginal: "2026:08:08 14:14:02",
      subsecondTimeOriginal: nil,
      offsetTimeOriginal: "+08:00",
      cameraMake: "NIKON CORPORATION",
      cameraModel: "NIKON Z 50",
      cameraSerialNumber: nil,
      cameraInternalSerialNumber: "synthetic-camera",
      shutterCount: 1
    )
    match.isSelectedForWrite = true
    var configuration = SourceConfiguration()
    configuration.photoDirectoryURL = fixture
    configuration.outputMode = .lightroomCatalogBridge
    let service = LiveGeoWorkflowService()

    let preview = try await service.previewWrite(matches: [match], configuration: configuration)
    XCTAssertEqual(preview.outputMode, .lightroomCatalogBridge)
    XCTAssertEqual(preview.createCount, 1)

    var report: ApplicationReport?
    for try await event in service.applyEvents(matches: [match], configuration: configuration) {
      if case .completed(_, let completed) = event { report = completed }
    }

    let manifestURL = fixture.appendingPathComponent("RawGeoSync.locations.jsonl")
    XCTAssertEqual(report?.artifactURL, manifestURL)
    XCTAssertEqual(report?.appliedCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: rawURL.deletingPathExtension().appendingPathExtension("xmp").path
      )
    )
    let contents = try String(contentsOf: manifestURL, encoding: .utf8)
    XCTAssertTrue(contents.contains("Z50/DSC_0001.NEF"))
    XCTAssertFalse(contents.contains(fixture.path))
  }

  func testBridgeReportCannotBeUndoneByTheApp() {
    let report = ApplicationReport(
      transactionID: UUID(),
      startedAt: Date(),
      finishedAt: Date(),
      appliedCount: 1,
      verifiedCount: 0,
      skippedCount: 0,
      failedCount: 0,
      outputDirectoryURL: nil,
      outputMode: .lightroomCatalogBridge
    )
    XCTAssertFalse(report.canUndo)
  }

  func testPluginInstallerCopiesBundledPluginIntoLightroomModules() throws {
    let fixture = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let source = fixture.appendingPathComponent("Bundled.lrplugin", isDirectory: true)
    let modules = fixture.appendingPathComponent("Modules", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("return { LrToolkitIdentifier = 'com.sssimplec.rawgeosync.lightroom' }".utf8).write(
      to: source.appendingPathComponent("Info.lua")
    )
    let installer = LightroomPluginInstaller(
      bundledPluginURL: source,
      modulesDirectoryURL: modules
    )

    XCTAssertEqual(installer.status(), .notInstalled)
    let installed = try installer.installOrUpdate()

    XCTAssertEqual(installed, modules.appendingPathComponent("RawGeoSync.lrplugin"))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: installed.appendingPathComponent("Info.lua").path))
    XCTAssertEqual(installer.status(), .installed)
  }

  func testAppBundleContainsLightroomPlugin() {
    XCTAssertNotEqual(LightroomPluginInstaller().status(), .unavailable)
  }

  func testPluginInstallerRefusesUnknownOccupiedTarget() throws {
    let fixture = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let source = fixture.appendingPathComponent("Bundled.lrplugin", isDirectory: true)
    let modules = fixture.appendingPathComponent("Modules", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("return { LrToolkitIdentifier = 'com.sssimplec.rawgeosync.lightroom' }".utf8).write(
      to: source.appendingPathComponent("Info.lua")
    )
    try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: false)
    try Data("occupied".utf8).write(
      to: modules.appendingPathComponent("RawGeoSync.lrplugin")
    )
    let installer = LightroomPluginInstaller(
      bundledPluginURL: source,
      modulesDirectoryURL: modules
    )

    XCTAssertThrowsError(try installer.installOrUpdate())
  }

  func testSingleGPXFileIsAcceptedAsSource() throws {
    let fixture = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let gpxFile = fixture.appendingPathComponent("single-track.GPX")
    try Data("<gpx version=\"1.1\"></gpx>".utf8).write(to: gpxFile)

    XCTAssertEqual(
      try LiveGeoWorkflowService.gpxFiles(at: gpxFile),
      [gpxFile.standardizedFileURL]
    )

    var configuration = SourceConfiguration()
    configuration.gpxSourceURL = gpxFile
    configuration.photoDirectoryURL = fixture
    XCTAssertTrue(configuration.isReady)
  }

  func testGPXDirectoryRecursivelyCollectsOnlyGPXFiles() throws {
    let fixture = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let nested = fixture.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(
      at: nested,
      withIntermediateDirectories: true
    )
    let first = fixture.appendingPathComponent("2025.gpx")
    let second = nested.appendingPathComponent("2026.GPX")
    try Data("<gpx/>".utf8).write(to: first)
    try Data("<gpx/>".utf8).write(to: second)
    try Data("not a track".utf8).write(to: fixture.appendingPathComponent("notes.txt"))

    XCTAssertEqual(
      try LiveGeoWorkflowService.gpxFiles(at: fixture),
      [first.standardizedFileURL, second.standardizedFileURL]
    )
  }

  func testNonGPXFileIsRejectedAsSource() throws {
    let fixture = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let textFile = fixture.appendingPathComponent("track.txt")
    try Data("not a track".utf8).write(to: textFile)

    XCTAssertThrowsError(try LiveGeoWorkflowService.gpxFiles(at: textFile)) { error in
      XCTAssertEqual(error.localizedDescription, "请选择扩展名为 .gpx 的轨迹文件。")
    }
  }

  func testFilteredSelectAllTogglesPhotoCheckmarks() {
    let workspace = WorkspaceViewModel(service: DemoGeoWorkflowService())
    workspace.matches = [
      makeMatch(id: "reliable", confidence: .reliable),
      makeMatch(id: "review-a", confidence: .review),
      makeMatch(id: "review-b", confidence: .review),
    ]
    workspace.confidenceFilter = .review

    workspace.toggleFilteredPhotoCheckmarks()

    XCTAssertFalse(workspace.matches[0].isSelectedForWrite)
    XCTAssertTrue(workspace.matches[1].isSelectedForWrite)
    XCTAssertTrue(workspace.matches[2].isSelectedForWrite)
    XCTAssertTrue(workspace.areAllFilteredPhotosChecked)

    workspace.toggleFilteredPhotoCheckmarks()
    XCTAssertFalse(workspace.matches[1].isSelectedForWrite)
    XCTAssertFalse(workspace.matches[2].isSelectedForWrite)
  }

  func testEvidenceOnlyAssetsAreNeverSelectedForWrite() {
    let workspace = WorkspaceViewModel(service: DemoGeoWorkflowService())
    workspace.matches = [
      makeMatch(id: "raw", confidence: .coarse),
      makeMatch(id: "evidence", confidence: .coarse, isWritableTarget: false),
    ]
    workspace.confidenceFilter = .coarse

    workspace.toggleFilteredPhotoCheckmarks()

    XCTAssertTrue(workspace.matches[0].isSelectedForWrite)
    XCTAssertFalse(workspace.matches[1].isSelectedForWrite)
  }

  func testConfirmGroupChecksEveryWritablePhotoInTheGroup() {
    let workspace = WorkspaceViewModel(service: DemoGeoWorkflowService())
    workspace.matches = [
      makeMatch(id: "a", confidence: .review, groupID: "stay-1"),
      makeMatch(id: "b", confidence: .review, groupID: "stay-1"),
      makeMatch(id: "c", confidence: .review, groupID: "stay-2"),
    ]
    workspace.selectedMatches = ["a"]

    workspace.confirmSelectedGroups()

    XCTAssertEqual(workspace.selectedMatches, ["a", "b"])
    XCTAssertTrue(workspace.matches[0].isSelectedForWrite)
    XCTAssertTrue(workspace.matches[1].isSelectedForWrite)
    XCTAssertFalse(workspace.matches[2].isSelectedForWrite)
  }

  private func makeMatch(
    id: String,
    confidence: MatchConfidence,
    groupID: String? = nil,
    isWritableTarget: Bool = true
  ) -> PhotoMatch {
    PhotoMatch(
      id: id,
      fileURL: URL(fileURLWithPath: "/tmp/\(id).NEF"),
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      previousTrackPoint: nil,
      nextTrackPoint: nil,
      coordinate: GeoCoordinate(latitude: 1, longitude: 2, altitude: nil),
      confidence: confidence,
      method: .stationary,
      granularity: .photoCluster,
      sourceLocationAccuracy: .notProvided,
      evidenceSummary: "合成测试证据",
      supportSpreadMeters: 50,
      confirmationGroupID: groupID,
      note: "测试",
      isSelectedForWrite: false,
      isWritableTarget: isWritableTarget,
      hasExistingGPS: false,
      hasProtectedExternalXMP: false
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RawGeoSync-GPXSourceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    return directory
  }
}
