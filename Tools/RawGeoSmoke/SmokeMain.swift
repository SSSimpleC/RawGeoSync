import Foundation

@main
enum RawGeoSmokeMain {
  static func main() async {
    do {
      switch Array(CommandLine.arguments.dropFirst()) {
      case ["capabilities", "--format", "json"]:
        try printJSON(capabilities())
      case let arguments where arguments.first == "dry-run":
        try await dryRun(arguments: Array(arguments.dropFirst()))
      default:
        throw WorkflowFailure(
          message:
            "用法：RawGeoSyncSmoke capabilities --format json，或 dry-run --gpx-directory <目录> --photo-directory <目录> --report <JSON> --read-only-source-directories"
        )
      }
    } catch {
      FileHandle.standardError.write(
        Data("RawGeoSync smoke failed: \(error.localizedDescription)\n".utf8)
      )
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func capabilities() -> [String: Any] {
    [
      "schemaVersion": 1,
      "features": ["fullCorpusDryRun": true],
      "guarantees": [
        "readOnlySourceDirectories": true,
        "writeTargets": "proprietary-raw-xmp-sidecar-only",
      ],
      "matchingRuleVersion": "2.0",
    ]
  }

  private static func dryRun(arguments: [String]) async throws {
    let options = try parseOptions(arguments)
    guard options.readOnlySourceDirectories else {
      throw WorkflowFailure(message: "dry-run 必须显式传入 --read-only-source-directories")
    }
    let gpxDirectory = try existingDirectory(options.gpxDirectory, label: "GPX")
    let photoDirectory = try existingDirectory(options.photoDirectory, label: "照片")
    guard let reportPath = options.report else {
      throw WorkflowFailure(message: "缺少 --report")
    }
    let reportURL = URL(fileURLWithPath: reportPath).standardizedFileURL
    guard !reportURL.path.hasPrefix(gpxDirectory.path + "/"),
      !reportURL.path.hasPrefix(photoDirectory.path + "/")
    else {
      throw WorkflowFailure(message: "报告不能写入任一只读输入目录")
    }

    let configuration = SourceConfiguration(
      gpxDirectoryURL: gpxDirectory,
      photoDirectoryURL: photoDirectory,
      matchingStrategy: .coverage
    )
    let service = LiveGeoWorkflowService()
    var snapshot: AnalysisSnapshot?
    for try await event in service.analysisEvents(for: configuration) {
      if case .completed(let completed) = event { snapshot = completed }
    }
    guard let snapshot else { throw WorkflowFailure(message: "分析未返回结果") }

    let methods = Dictionary(grouping: snapshot.matches, by: { $0.method.rawValue })
      .mapValues(\.count)
    let granularities = Dictionary(grouping: snapshot.matches, by: { $0.granularity.rawValue })
      .mapValues(\.count)
    let unmatchedReasons = Dictionary(
      grouping: snapshot.matches.filter { $0.confidence == .unmatched },
      by: \PhotoMatch.evidenceSummary
    ).mapValues(\.count)
    let output: [String: Any] = [
      "schemaVersion": 1,
      "mode": "dry-run",
      "matchingRuleVersion": "2.0",
      "strategy": "coverage",
      "totalWritableTargets": snapshot.matches.count,
      "reliable": snapshot.reliableCount,
      "review": snapshot.reviewCount,
      "coarse": snapshot.coarseCount,
      "unmatched": snapshot.unmatchedCount,
      "selectedForWrite": snapshot.matches.count(where: \.isSelectedForWrite),
      "confirmationGroups": Set(snapshot.matches.compactMap(\.confirmationGroupID)).count,
      "trackCoordinatesShown": snapshot.trackCoordinates.count,
      "warningCount": snapshot.warnings.count,
      "clockSuggestionCount": snapshot.clockSuggestions.count,
      "methods": methods,
      "granularities": granularities,
      "unmatchedReasons": unmatchedReasons,
      "sourceDirectoriesModified": false,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(
      at: reportURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: reportURL, options: .atomic)
    try printJSON(output)
  }

  private struct Options {
    var gpxDirectory: String?
    var photoDirectory: String?
    var report: String?
    var readOnlySourceDirectories = false
  }

  private static func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--gpx-directory":
        guard index + 1 < arguments.count else { throw WorkflowFailure(message: "GPX 参数缺值") }
        options.gpxDirectory = arguments[index + 1]
        index += 2
      case "--photo-directory":
        guard index + 1 < arguments.count else { throw WorkflowFailure(message: "照片参数缺值") }
        options.photoDirectory = arguments[index + 1]
        index += 2
      case "--report":
        guard index + 1 < arguments.count else { throw WorkflowFailure(message: "报告参数缺值") }
        options.report = arguments[index + 1]
        index += 2
      case "--read-only-source-directories":
        options.readOnlySourceDirectories = true
        index += 1
      default:
        throw WorkflowFailure(message: "未知参数：\(arguments[index])")
      }
    }
    return options
  }

  private static func existingDirectory(_ path: String?, label: String) throws -> URL {
    guard let path else { throw WorkflowFailure(message: "缺少 \(label) 目录") }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw WorkflowFailure(message: "\(label) 目录不存在") }
    return url
  }

  private static func printJSON(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
}
