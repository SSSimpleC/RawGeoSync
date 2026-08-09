import Foundation

protocol GeoWorkflowServicing: Sendable {
  var implementationLabel: String { get }
  var isSimulation: Bool { get }

  func analysisEvents(for configuration: SourceConfiguration) -> AsyncThrowingStream<
    AnalysisEvent, Error
  >
  func previewWrite(matches: [PhotoMatch], configuration: SourceConfiguration) async throws
    -> WritePreview
  func applyEvents(matches: [PhotoMatch], configuration: SourceConfiguration)
    -> AsyncThrowingStream<ApplyEvent, Error>
  func undo(report: ApplicationReport, matches: [PhotoMatch]) async throws -> [PhotoMatch]
  func interruptedTransactionCount() async throws -> Int
}

struct DemoGeoWorkflowService: GeoWorkflowServicing {
  let implementationLabel = "演示工作流"
  let isSimulation = true

  func analysisEvents(for configuration: SourceConfiguration) -> AsyncThrowingStream<
    AnalysisEvent, Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let steps = [
            (0.12, "读取 GPX 轨迹…"),
            (0.31, "批量读取照片拍摄时间…"),
            (0.54, "重建逻辑轨迹段…"),
            (0.76, "识别移动、停留与缺轨区间…"),
            (0.93, "计算匹配置信度与来源信息…"),
          ]

          for step in steps {
            try Task.checkCancellation()
            continuation.yield(.progress(fraction: step.0, message: step.1))
            try await Task.sleep(for: .milliseconds(130))
          }

          let snapshot = makeDemoSnapshot(configuration: configuration)
          continuation.yield(.completed(snapshot))
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func previewWrite(matches: [PhotoMatch], configuration: SourceConfiguration) async throws
    -> WritePreview
  {
    let selected = matches.count(where: { $0.isSelectedForWrite && $0.coordinate != nil })
    return WritePreview(
      selectedCount: selected,
      createCount: selected,
      updateCount: 0,
      alreadyAppliedCount: 0,
      conflictCount: 0
    )
  }

  func applyEvents(
    matches: [PhotoMatch],
    configuration: SourceConfiguration
  ) -> AsyncThrowingStream<ApplyEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let eligible = matches.filter { $0.isSelectedForWrite && $0.coordinate != nil }
          let steps = max(eligible.count, 1)
          var updated = matches

          for (index, match) in eligible.enumerated() {
            try Task.checkCancellation()
            let fraction = Double(index + 1) / Double(steps)
            continuation.yield(
              .progress(
                fraction: fraction,
                message: "验证 \(match.fileName) 的 XMP…"
              )
            )
            if let targetIndex = updated.firstIndex(where: { $0.id == match.id }) {
              updated[targetIndex].verification = .verified
            }
            try await Task.sleep(for: .milliseconds(22))
          }

          for index in updated.indices where updated[index].coordinate == nil {
            updated[index].verification = .skipped
          }

          let now = Date()
          let report = ApplicationReport(
            transactionID: nil,
            startedAt: now.addingTimeInterval(-0.6),
            finishedAt: now,
            appliedCount: eligible.count,
            verifiedCount: eligible.count,
            skippedCount: matches.count - eligible.count,
            failedCount: 0,
            outputDirectoryURL: configuration.photoDirectoryURL
          )
          continuation.yield(.completed(matches: updated, report: report))
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func undo(report: ApplicationReport, matches: [PhotoMatch]) async throws -> [PhotoMatch] {
    try await Task.sleep(for: .milliseconds(350))
    return matches.map { match in
      var copy = match
      copy.verification = copy.coordinate == nil ? .skipped : .undone
      return copy
    }
  }

  func interruptedTransactionCount() async throws -> Int { 0 }

  private func makeDemoSnapshot(configuration: SourceConfiguration) -> AnalysisSnapshot {
    let calendar = Calendar(identifier: .gregorian)
    let timeZone = configuration.timeZone
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = timeZone
    components.year = 2026
    components.month = 8
    components.day = 8
    components.hour = 14
    components.minute = 14
    components.second = 2
    let firstDate = components.date ?? Date()

    let base = GeoCoordinate(latitude: 22.9950, longitude: 113.7480, altitude: 12)
    var track: [GeoCoordinate] = []
    for index in 0..<18 {
      let step = Double(index)
      let latitude = base.latitude + step * 0.00042
      let longitudeDrift = sin(step / 3.0) * 0.0012
      let longitude = base.longitude + longitudeDrift + step * 0.00031
      let altitude = 12.0 + Double(index % 4)
      track.append(
        GeoCoordinate(latitude: latitude, longitude: longitude, altitude: altitude)
      )
    }

    let matches = (0..<52).map { index -> PhotoMatch in
      let previous = track[min(index / 3, track.count - 2)]
      let next = track[min(index / 3 + 1, track.count - 1)]
      let isStationary = (23..<46).contains(index)
      let isUnmatched = index == 39 || index == 40
      let coordinate =
        isUnmatched ? nil : (isStationary ? previous : GeoCoordinate.midpoint(previous, next))
      let confidence: MatchConfidence =
        isUnmatched ? .unmatched : (isStationary ? .review : .reliable)
      let method: MatchMethod =
        isUnmatched ? .unavailable : (isStationary ? .stationary : .interpolated)

      return PhotoMatch(
        id: String(format: "demo-Z50-%04d", 386 + index),
        fileURL: (configuration.photoDirectoryURL ?? URL(fileURLWithPath: "/演示/Z50"))
          .appendingPathComponent(String(format: "DSC_%04d.NEF", 386 + index)),
        capturedAt: firstDate.addingTimeInterval(Double(index) * 155),
        previousTrackPoint: previous,
        nextTrackPoint: next,
        coordinate: coordinate,
        confidence: confidence,
        method: method,
        granularity: isUnmatched ? .unavailable : (isStationary ? .photoCluster : .track),
        sourceLocationAccuracy: .notProvided,
        evidenceSummary: isUnmatched ? "缺少可安全采用的证据" : "演示轨迹证据",
        supportSpreadMeters: isStationary ? 96.7 : 101.0,
        confirmationGroupID: isStationary ? "demo-stay" : nil,
        note: isUnmatched
          ? "长间隔且空间跨度过大，已阻止自动匹配" : (isStationary ? "长时间内位置变化较小，按停留区间处理" : "前后轨迹点连续，已执行线性插值"),
        isSelectedForWrite: confidence == .reliable,
        isWritableTarget: true,
        hasExistingGPS: false,
        hasProtectedExternalXMP: false
      )
    }

    return AnalysisSnapshot(matches: matches, trackCoordinates: track, warnings: [])
  }
}
