import Foundation
import MetadataInfrastructure
import RawGeoCore

struct LiveGeoWorkflowService: GeoWorkflowServicing {
  let implementationLabel = "本地 ExifTool 13.59"
  let isSimulation = false

  private let exifToolScriptURL: URL
  private let backupRootURL: URL

  init(
    exifToolScriptURL: URL = Self.defaultExifToolScriptURL(),
    backupRootURL: URL = Self.defaultBackupRootURL()
  ) {
    self.exifToolScriptURL = exifToolScriptURL.standardizedFileURL
    self.backupRootURL = backupRootURL.standardizedFileURL
  }

  func analysisEvents(for configuration: SourceConfiguration) -> AsyncThrowingStream<
    AnalysisEvent, Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        do {
          guard let trackURL = configuration.trackURL,
            let photoDirectoryURL = configuration.photoDirectoryURL
          else {
            throw WorkflowFailure(message: "请先选择 GPX 文件和照片目录。")
          }

          continuation.yield(.progress(fraction: 0.05, message: "检查内置 ExifTool…"))
          let client = try makeClient()
          _ = try await client.checkVersion()

          continuation.yield(.progress(fraction: 0.16, message: "枚举支持的照片…"))
          let rawFiles = try Self.photoFiles(in: photoDirectoryURL)
          guard !rawFiles.isEmpty else {
            throw WorkflowFailure(message: "所选目录中没有支持的照片。")
          }

          continuation.yield(.progress(fraction: 0.30, message: "批量读取原始拍摄时间…"))
          let metadata = try await client.readRawMetadata(rawFiles)
          let captures = try Self.makeCaptures(
            metadata: metadata,
            timeZoneIdentifier: configuration.timeZoneIdentifier,
            cameraClockDelta: TimeInterval(configuration.cameraClockOffsetSeconds)
          )

          continuation.yield(.progress(fraction: 0.50, message: "流式读取 GPX 轨迹…"))
          try Task.checkCancellation()
          let document = try GPXStreamParser().parse(url: trackURL)

          continuation.yield(.progress(fraction: 0.68, message: "重建轨迹段并识别缺轨…"))
          try Task.checkCancellation()
          let normalizedTrack = TrackNormalizer().normalize(document)

          continuation.yield(.progress(fraction: 0.84, message: "计算匹配与置信度…"))
          let results = GeoMatcher().match(
            photos: captures.map(\.capture),
            track: normalizedTrack
          )
          let metadataByPath = Dictionary(
            uniqueKeysWithValues: metadata.map { ($0.rawFile.url.path, $0) }
          )
          let filesByPath = Dictionary(
            uniqueKeysWithValues: captures.map { ($0.capture.id, $0.file) }
          )
          let matches = results.compactMap { result -> PhotoMatch? in
            guard let file = filesByPath[result.photo.id] else { return nil }
            return Self.makePhotoMatch(
              result: result,
              file: file,
              rawMetadata: metadataByPath[file.url.path],
              writeAltitude: configuration.writeAltitude
            )
          }
          .sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
          }
          let trackCoordinates = Self.visibleTrackCoordinates(
            track: normalizedTrack,
            captures: captures.map(\.capture)
          )

          continuation.yield(.progress(fraction: 1, message: "分析完成"))
          continuation.yield(
            .completed(AnalysisSnapshot(matches: matches, trackCoordinates: trackCoordinates))
          )
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
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
    let requests = try Self.makeWriteRequests(matches: matches, configuration: configuration)
    guard !requests.isEmpty else {
      return WritePreview(
        selectedCount: 0,
        createCount: 0,
        updateCount: 0,
        alreadyAppliedCount: 0,
        conflictCount: 0
      )
    }
    let (client, coordinator) = try makeCoordinator()
    _ = try await client.checkVersion()
    let plan = try await coordinator.makeWritePlan(requests)
    var createCount = 0
    var updateCount = 0
    var alreadyAppliedCount = 0
    var conflictURLs = Set<URL>()
    for item in plan.items {
      switch item.disposition {
      case .create: createCount += 1
      case .update: updateCount += 1
      case .alreadyApplied: alreadyAppliedCount += 1
      case .conflict: conflictURLs.insert(item.rawFile.url)
      }
    }
    return WritePreview(
      selectedCount: requests.count,
      createCount: createCount,
      updateCount: updateCount,
      alreadyAppliedCount: alreadyAppliedCount,
      conflictCount: conflictURLs.count,
      conflictFileURLs: conflictURLs
    )
  }

  func applyEvents(
    matches: [PhotoMatch],
    configuration: SourceConfiguration
  ) -> AsyncThrowingStream<ApplyEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        let startedAt = Date()
        do {
          let requests = try Self.makeWriteRequests(matches: matches, configuration: configuration)
          guard !requests.isEmpty else {
            throw WorkflowFailure(message: "没有已确认且可写入的照片。")
          }
          continuation.yield(.progress(fraction: 0.08, message: "重新检查文件摘要…"))
          let (client, coordinator) = try makeCoordinator()
          _ = try await client.checkVersion()
          let plan = try await coordinator.makeWritePlan(requests)

          continuation.yield(.progress(fraction: 0.35, message: "原子写入并复读验证 XMP…"))
          let applyReport = try await coordinator.apply(plan)
          let manifest = try await coordinator.manifest(transactionID: applyReport.transactionID)
          var updated = matches
          let recordsByPath = Dictionary(
            uniqueKeysWithValues: manifest.records.map { ($0.planItem.rawFile.url.path, $0) }
          )
          for index in updated.indices {
            guard updated[index].isSelectedForWrite else {
              updated[index].verification = .skipped
              continue
            }
            guard let record = recordsByPath[updated[index].fileURL.standardizedFileURL.path] else {
              updated[index].verification = .skipped
              continue
            }
            switch record.status {
            case .applied: updated[index].verification = .verified
            case .failed: updated[index].verification = .failed
            case .undone: updated[index].verification = .undone
            case .pending, .skipped, .applying: updated[index].verification = .skipped
            }
          }
          _ = try? await coordinator.cleanupBackups()
          let selectedCount = requests.count
          let skippedCount = matches.count - selectedCount + applyReport.skippedCount
          let report = ApplicationReport(
            transactionID: applyReport.transactionID,
            startedAt: startedAt,
            finishedAt: Date(),
            appliedCount: applyReport.appliedCount,
            verifiedCount: applyReport.appliedCount,
            skippedCount: skippedCount,
            failedCount: applyReport.failedCount,
            outputDirectoryURL: configuration.photoDirectoryURL
          )
          continuation.yield(.progress(fraction: 1, message: "写入与复读验证完成"))
          continuation.yield(.completed(matches: updated, report: report))
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func undo(report: ApplicationReport, matches: [PhotoMatch]) async throws -> [PhotoMatch] {
    guard let transactionID = report.transactionID else {
      throw WorkflowFailure(message: "当前结果没有可撤销的写入事务。")
    }
    let (_, coordinator) = try makeCoordinator()
    try await coordinator.undo(transactionID: transactionID)
    let manifest = try await coordinator.manifest(transactionID: transactionID)
    let statusByPath = Dictionary(
      uniqueKeysWithValues: manifest.records.map { ($0.planItem.rawFile.url.path, $0.status) }
    )
    return matches.map { match in
      var updated = match
      if statusByPath[match.fileURL.standardizedFileURL.path] == .undone {
        updated.verification = .undone
      }
      return updated
    }
  }

  func interruptedTransactionCount() async throws -> Int {
    let (_, coordinator) = try makeCoordinator()
    let ids = try await coordinator.transactionIDs()
    var count = 0
    for id in ids {
      let status = try await coordinator.manifest(transactionID: id).status
      if status == .applying || status == .undoing || status == .undoFailed {
        count += 1
      }
    }
    return count
  }

  private func makeClient() throws -> ExifToolClient {
    guard FileManager.default.isExecutableFile(atPath: exifToolScriptURL.path) else {
      throw WorkflowFailure(message: "应用资源中缺少可执行的 ExifTool。")
    }
    return ExifToolClient(
      configuration: try .bundledPerl(scriptURL: exifToolScriptURL)
    )
  }

  private func makeCoordinator() throws -> (ExifToolClient, XMPTransactionCoordinator) {
    let client = try makeClient()
    return (
      client,
      XMPTransactionCoordinator(metadataTool: client, backupRoot: backupRootURL)
    )
  }

  private static func photoFiles(in directory: URL) throws -> [ReadOnlyRawFile] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    return
      try urls
      .filter { ReadOnlyRawFile.supportedExtensions.contains($0.pathExtension.lowercased()) }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
      .map(ReadOnlyRawFile.init(url:))
  }

  private static func makeCaptures(
    metadata: [RawPhotoMetadata],
    timeZoneIdentifier: String,
    cameraClockDelta: TimeInterval
  ) throws -> [(capture: PhotoCapture, file: ReadOnlyRawFile)] {
    try metadata.map { item in
      guard let original = item.dateTimeOriginal else {
        throw WorkflowFailure(message: "\(item.rawFile.url.lastPathComponent) 缺少 DateTimeOriginal。")
      }
      let timestamp = try parsePhotoTimestamp(
        original,
        subsecond: item.subsecondTimeOriginal,
        offset: item.offsetTimeOriginal
      )
      let utc = try TimeNormalizer().normalize(
        timestamp,
        timeZoneIdentifier: timeZoneIdentifier,
        cameraClockDelta: cameraClockDelta
      )
      return (
        PhotoCapture(id: item.rawFile.url.path, captureTimeUTC: utc),
        item.rawFile
      )
    }
  }

  private static func parsePhotoTimestamp(
    _ original: String,
    subsecond: String?,
    offset: String?
  ) throws -> PhotoCaptureTimestamp {
    let parts = original.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else {
      throw WorkflowFailure(message: "无法解析拍摄时间：\(original)")
    }
    let date = parts[0].split(separator: ":").compactMap { Int($0) }
    let time = parts[1].split(separator: ":").compactMap { Int($0) }
    guard date.count == 3, time.count == 3 else {
      throw WorkflowFailure(message: "无法解析拍摄时间：\(original)")
    }
    let digits = (subsecond ?? "").filter(\.isNumber)
    let nanosecond: Int
    if digits.isEmpty {
      nanosecond = 0
    } else {
      let normalized = String(digits.prefix(9)).padding(
        toLength: 9,
        withPad: "0",
        startingAt: 0
      )
      nanosecond = Int(normalized) ?? 0
    }
    return PhotoCaptureTimestamp(
      year: date[0],
      month: date[1],
      day: date[2],
      hour: time[0],
      minute: time[1],
      second: time[2],
      nanosecond: nanosecond,
      originalUTCOffsetSeconds: parseUTCOffset(offset)
    )
  }

  private static func parseUTCOffset(_ value: String?) -> Int? {
    guard let value, let signCharacter = value.first,
      signCharacter == "+" || signCharacter == "-"
    else { return nil }
    let numbers = value.dropFirst().split(separator: ":").compactMap { Int($0) }
    guard numbers.count == 2, numbers[0] <= 18, numbers[1] < 60 else { return nil }
    let sign = signCharacter == "-" ? -1 : 1
    return sign * (numbers[0] * 3_600 + numbers[1] * 60)
  }

  private static func makePhotoMatch(
    result: PhotoMatchResult,
    file: ReadOnlyRawFile,
    rawMetadata: RawPhotoMetadata?,
    writeAltitude: Bool
  ) -> PhotoMatch {
    let firstCandidate = result.candidates.first
    let previous = firstCandidate.map { appCoordinate($0.startPoint) }
    let next = firstCandidate?.endPoint.map(appCoordinate)
    let coordinate = result.coordinate.map {
      GeoCoordinate(
        latitude: $0.latitude,
        longitude: $0.longitude,
        altitude: writeAltitude ? result.elevationMeters : nil
      )
    }
    let confidence: MatchConfidence
    switch result.confidence {
    case .reliable: confidence = .reliable
    case .review: confidence = .review
    case .unmatched: confidence = .unmatched
    }
    let existingGPS = rawMetadata?.gps != nil
    let sourceAccuracy: SourceLocationAccuracy
    switch result.sensorAccuracy {
    case .known(let meters): sourceAccuracy = .meters(meters)
    case .unknown: sourceAccuracy = .notProvided
    }
    return PhotoMatch(
      id: UUID(),
      fileURL: file.url,
      capturedAt: result.photo.captureTimeUTC,
      previousTrackPoint: previous,
      nextTrackPoint: next,
      coordinate: coordinate,
      confidence: existingGPS ? .review : confidence,
      method: appMethod(result.mode),
      sourceLocationAccuracy: sourceAccuracy,
      note: existingGPS ? "文件已有 GPS，默认跳过；重新勾选写入即表示明确替换" : note(result),
      isSelectedForWrite: confidence == .reliable && !existingGPS,
      hasExistingGPS: existingGPS
    )
  }

  private static func appCoordinate(_ point: TrackPoint) -> GeoCoordinate {
    GeoCoordinate(
      latitude: point.coordinate.latitude,
      longitude: point.coordinate.longitude,
      altitude: point.elevationMeters
    )
  }

  private static func appMethod(_ mode: MatchMode) -> MatchMethod {
    switch mode {
    case .exact: .exact
    case .reliableInterpolation: .interpolated
    case .reviewInterpolation: .reviewInterpolation
    case .stayCandidate: .stationary
    case .nearest: .nearest
    case .ambiguous, .unmatched: .unavailable
    }
  }

  private static func note(_ result: PhotoMatchResult) -> String {
    switch result.mode {
    case .exact: "拍摄时间与轨迹点相差不超过2秒"
    case .reliableInterpolation: "轨迹点连续，已按拍摄时间进行大圆插值"
    case .reviewInterpolation: "轨迹较稀疏，确认后才会写入"
    case .stayCandidate: "长时间内端点接近，可能停留也可能离开后返回，需整批确认"
    case .nearest: "仅接近缺轨边界，需确认最近轨迹点"
    case .ambiguous: "多个轨迹候选位置冲突，禁止自动写入"
    case .unmatched: "没有安全的轨迹覆盖，已阻止自动匹配"
    }
  }

  private static func visibleTrackCoordinates(
    track: NormalizedTrack,
    captures: [PhotoCapture]
  ) -> [GeoCoordinate] {
    guard let minimum = captures.map(\.captureTimeUTC).min(),
      let maximum = captures.map(\.captureTimeUTC).max()
    else { return [] }
    let lower = minimum.addingTimeInterval(-6 * 60 * 60)
    let upper = maximum.addingTimeInterval(6 * 60 * 60)
    let all = track.segments.flatMap(\.points)
      .filter { $0.timestamp >= lower && $0.timestamp <= upper }
      .map(appCoordinate)
    guard all.count > 5_000 else { return all }
    let step = Int(ceil(Double(all.count) / 5_000.0))
    var result = stride(from: 0, to: all.count, by: step).map { all[$0] }
    if let last = all.last, result.last != last { result.append(last) }
    return result
  }

  private static func makeWriteRequests(
    matches: [PhotoMatch],
    configuration: SourceConfiguration
  ) throws -> [SidecarWriteRequest] {
    try matches.compactMap { match in
      guard match.isSelectedForWrite, let coordinate = match.coordinate else { return nil }
      let raw = try ReadOnlyRawFile(url: match.fileURL)
      let gps = try GPSMetadata(
        latitude: coordinate.latitude,
        longitude: coordinate.longitude,
        altitude: configuration.writeAltitude ? coordinate.altitude : nil
      )
      return SidecarWriteRequest(
        rawFile: raw,
        gps: gps,
        existingGPSPolicy: match.hasExistingGPS ? .replace : .skip
      )
    }
  }

  private static func defaultExifToolScriptURL() -> URL {
    if let bundled = Bundle.main.url(
      forResource: "exiftool",
      withExtension: nil,
      subdirectory: "ExifTool"
    ) {
      return bundled
    }
    return URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Vendor/ExifTool/exiftool")
  }

  private static func defaultBackupRootURL() -> URL {
    let applicationSupport =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.homeDirectoryForCurrentUser
    return
      applicationSupport
      .appendingPathComponent("RawGeoSync", isDirectory: true)
      .appendingPathComponent("Transactions", isDirectory: true)
  }
}
