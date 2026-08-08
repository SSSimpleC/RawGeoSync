import Foundation

@main
enum RawGeoSmokeMain {
  static func main() async {
    do {
      let arguments = CommandLine.arguments
      guard arguments.count == 3 || arguments.count == 4 else {
        throw WorkflowFailure(
          message:
            "用法：RawGeoSyncSmoke <track.gpx> <photo-directory> [--expect-current-sample|--apply-and-undo]"
        )
      }
      let configuration = SourceConfiguration(
        trackURL: URL(fileURLWithPath: arguments[1]),
        photoDirectoryURL: URL(fileURLWithPath: arguments[2])
      )
      let service = LiveGeoWorkflowService()
      var finalSnapshot: AnalysisSnapshot?
      for try await event in service.analysisEvents(for: configuration) {
        if case .completed(let snapshot) = event {
          finalSnapshot = snapshot
        }
      }
      guard let snapshot = finalSnapshot else {
        throw WorkflowFailure(message: "分析未返回结果")
      }
      let selectedReliable = snapshot.matches.count {
        $0.confidence == .reliable && $0.isSelectedForWrite
      }
      let selectedReview = snapshot.matches.count {
        $0.confidence == .review && $0.isSelectedForWrite
      }
      var output: [String: Any] = [
        "total": snapshot.matches.count,
        "reliable": snapshot.reliableCount,
        "review": snapshot.reviewCount,
        "unmatched": snapshot.unmatchedCount,
        "selectedReliable": selectedReliable,
        "selectedReview": selectedReview,
        "trackCoordinates": snapshot.trackCoordinates.count,
      ]
      if arguments.last == "--expect-current-sample" {
        guard snapshot.matches.count == 52,
          snapshot.reliableCount == 29,
          snapshot.reviewCount == 23,
          snapshot.unmatchedCount == 0,
          selectedReliable == 29,
          selectedReview == 0
        else {
          throw WorkflowFailure(message: "真实样本黄金计数不符：\(output)")
        }
      }
      if arguments.last == "--apply-and-undo" {
        let preview = try await service.previewWrite(
          matches: snapshot.matches,
          configuration: configuration
        )
        guard preview.createCount == selectedReliable,
          preview.updateCount == 0,
          preview.conflictCount == 0
        else {
          throw WorkflowFailure(message: "首次写入预检不符：\(preview.message)")
        }

        var appliedMatches: [PhotoMatch]?
        var applicationReport: ApplicationReport?
        for try await event in service.applyEvents(
          matches: snapshot.matches,
          configuration: configuration
        ) {
          if case .completed(let matches, let report) = event {
            appliedMatches = matches
            applicationReport = report
          }
        }
        guard let appliedMatches, let applicationReport,
          applicationReport.appliedCount == selectedReliable,
          applicationReport.failedCount == 0
        else {
          throw WorkflowFailure(message: "真实副本写入未完整成功")
        }

        let xmpBeforeIdempotency = try xmpModificationDates(in: configuration.photoDirectoryURL!)
        let secondPreview = try await service.previewWrite(
          matches: appliedMatches,
          configuration: configuration
        )
        let xmpAfterIdempotency = try xmpModificationDates(in: configuration.photoDirectoryURL!)
        guard secondPreview.alreadyAppliedCount == selectedReliable,
          xmpBeforeIdempotency == xmpAfterIdempotency
        else {
          throw WorkflowFailure(message: "重复运行未保持语义幂等或修改了 XMP mtime")
        }

        let undone = try await service.undo(report: applicationReport, matches: appliedMatches)
        let remainingXMP = try xmpModificationDates(in: configuration.photoDirectoryURL!).count
        guard remainingXMP == 0,
          undone.count(where: { $0.verification == .undone }) == selectedReliable
        else {
          throw WorkflowFailure(message: "撤销后仍有 XMP 或撤销状态不完整")
        }
        output["applied"] = applicationReport.appliedCount
        output["idempotent"] = true
        output["undone"] = selectedReliable
      }
      let data = try JSONSerialization.data(
        withJSONObject: output,
        options: [.prettyPrinted, .sortedKeys]
      )
      print(String(decoding: data, as: UTF8.self))
    } catch {
      FileHandle.standardError.write(
        Data("RawGeoSync smoke failed: \(error.localizedDescription)\n".utf8))
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func xmpModificationDates(in directory: URL) throws -> [String: Date] {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    return try Dictionary(
      uniqueKeysWithValues:
        files
        .filter { $0.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame }
        .map {
          let values = try $0.resourceValues(forKeys: [.contentModificationDateKey])
          return ($0.lastPathComponent, values.contentModificationDate ?? .distantPast)
        }
    )
  }
}
