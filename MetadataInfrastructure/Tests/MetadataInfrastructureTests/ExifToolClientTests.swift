import Foundation
import Testing

@testable import MetadataInfrastructure

private actor RecordingRunner: ExecutableRunning {
  private var results: [Result<ExecutableResult, Error>]
  private(set) var invocations: [ExecutableInvocation] = []

  init(results: [Result<ExecutableResult, Error>]) {
    self.results = results
  }

  func run(_ invocation: ExecutableInvocation, timeout: Duration) async throws -> ExecutableResult {
    invocations.append(invocation)
    guard !results.isEmpty else {
      throw MetadataInfrastructureError.malformedExifToolOutput("没有脚本化结果")
    }
    return try results.removeFirst().get()
  }

  func recordedInvocations() -> [ExecutableInvocation] { invocations }
}

@Suite("ExifTool client contract")
struct ExifToolClientTests {
  @Test("checks and rejects versions below the pinned minimum")
  func versionCheck() async throws {
    let success = ExecutableResult(
      terminationStatus: 0,
      standardOutput: Data("13.59\n".utf8),
      standardError: Data()
    )
    let runner = RecordingRunner(results: [.success(success)])
    let client = ExifToolClient(
      runner: runner,
      configuration: ExifToolConfiguration(
        executableURL: URL(fileURLWithPath: "/fake/perl"),
        leadingArguments: ["/bundle/exiftool"],
        minimumVersion: try ExifToolVersion("13.59")
      )
    )

    #expect(try await client.checkVersion() == ExifToolVersion("13.59"))
    let invocation = try #require(await runner.recordedInvocations().first)
    #expect(invocation.executableURL.path == "/fake/perl")
    #expect(invocation.arguments == ["/bundle/exiftool", "-ver"])
  }

  @Test("parses numeric and string subseconds and restores input order")
  func parsesMixedJSONAndRestoresOrder() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstURL = directory.appendingPathComponent("中文 1.NEF")
    let secondURL = directory.appendingPathComponent("quote'2.NEF")
    try Data("raw1".utf8).write(to: firstURL)
    try Data("raw2".utf8).write(to: secondURL)
    let first = try ReadOnlyRawFile(url: firstURL)
    let second = try ReadOnlyRawFile(url: secondURL)

    let json = """
      [
        {
          "SourceFile": "\(escaped(secondURL.path))",
          "EXIF:DateTimeOriginal": "2026:08:08 14:15:00",
          "EXIF:SubSecTimeOriginal": 66,
          "EXIF:OffsetTimeOriginal": "+08:00",
          "EXIF:GPSLatitude": 22.5
        },
        {
          "SourceFile": "\(escaped(firstURL.path))",
          "EXIF:DateTimeOriginal": "2026:08:08 14:14:00",
          "EXIF:SubSecTimeOriginal": "080",
          "EXIF:OffsetTimeOriginal": "+08:00",
          "EXIF:GPSLatitude": 22.5,
          "EXIF:GPSLongitude": 113.7,
          "EXIF:GPSAltitude": 10,
          "EXIF:GPSAltitudeRef": 1
        }
      ]
      """
    let runner = RecordingRunner(results: [
      .success(
        ExecutableResult(
          terminationStatus: 0,
          standardOutput: Data(json.utf8),
          standardError: Data()
        ))
    ])
    let client = ExifToolClient(
      runner: runner,
      configuration: ExifToolConfiguration(
        executableURL: URL(fileURLWithPath: "/fake/exiftool"),
        minimumVersion: try ExifToolVersion("13.59")
      )
    )

    let metadata = try await client.readRawMetadata([first, second])
    #expect(metadata.map(\.rawFile) == [first, second])
    #expect(metadata[0].subsecondTimeOriginal == "080")
    #expect(metadata[1].subsecondTimeOriginal == "66")
    #expect(metadata[0].gps?.altitude == -10)
    #expect(metadata[1].gps == nil)
    #expect(metadata[1].gpsIsPartial)

    let invocation = try #require(await runner.recordedInvocations().first)
    #expect(invocation.arguments.contains(firstURL.path))
    #expect(invocation.arguments.contains(secondURL.path))
    #expect(!invocation.arguments.contains("/bin/sh"))
    #expect(invocation.arguments.contains("-EXIF:GPSLatitude#"))
    #expect(!invocation.arguments.contains("-n"))
  }

  @Test("surfaces nonzero process status")
  func nonzeroStatus() async throws {
    let runner = RecordingRunner(results: [
      .success(
        ExecutableResult(
          terminationStatus: 2,
          standardOutput: Data(),
          standardError: Data("bad metadata".utf8)
        ))
    ])
    let client = ExifToolClient(
      runner: runner,
      configuration: ExifToolConfiguration(
        executableURL: URL(fileURLWithPath: "/fake/exiftool"),
        minimumVersion: try ExifToolVersion("13.59")
      )
    )

    await #expect(throws: MetadataInfrastructureError.self) {
      try await client.checkVersion()
    }
  }

  @Test("real process runner terminates on timeout")
  func processTimeout() async {
    let runner = ProcessExecutableRunner()
    let invocation = ExecutableInvocation(
      executableURL: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["2"]
    )
    await #expect(throws: MetadataInfrastructureError.timedOut) {
      try await runner.run(invocation, timeout: .milliseconds(50))
    }
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("MetadataInfrastructureTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func escaped(_ value: String) -> String {
  value.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
