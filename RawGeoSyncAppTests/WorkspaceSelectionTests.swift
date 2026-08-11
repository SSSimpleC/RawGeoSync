import XCTest

@testable import RawGeoSync

@MainActor
final class WorkspaceSelectionTests: XCTestCase {
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
