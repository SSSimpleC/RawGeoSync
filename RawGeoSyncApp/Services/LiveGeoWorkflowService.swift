import CryptoKit
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
          guard let gpxDirectoryURL = configuration.gpxDirectoryURL,
            let photoDirectoryURL = configuration.photoDirectoryURL
          else {
            throw WorkflowFailure(message: "请先选择 GPX 目录和照片目录。")
          }

          continuation.yield(.progress(fraction: 0.05, message: "检查内置 ExifTool…"))
          let client = try makeClient()
          _ = try await client.checkVersion()

          continuation.yield(.progress(fraction: 0.14, message: "递归枚举照片与只读证据…"))
          let mediaFiles = try Self.photoFiles(in: photoDirectoryURL)
          guard !mediaFiles.isEmpty else {
            throw WorkflowFailure(message: "所选目录中没有支持的照片。")
          }

          continuation.yield(.progress(fraction: 0.27, message: "批量读取照片、相机与 GPS 元数据…"))
          let mediaRead = try await Self.readMediaMetadataInBatches(
            client: client,
            files: mediaFiles,
            batchSize: 250,
            progress: { completed, total in
              let fraction = 0.27 + 0.15 * Double(completed) / Double(max(total, 1))
              continuation.yield(
                .progress(
                  fraction: fraction,
                  message: "已读取 \(completed) / \(total) 个媒体文件的元数据…"
                )
              )
            }
          )
          var assetBuild = Self.makeAssets(
            metadata: mediaRead.metadata,
            photoRootURL: photoDirectoryURL,
            timeZoneIdentifier: configuration.timeZoneIdentifier,
            globalCameraClockDelta: TimeInterval(configuration.cameraClockOffsetSeconds),
            cameraClockOffsetsByID: configuration.cameraClockOffsetsByID
          )
          continuation.yield(.progress(fraction: 0.43, message: "只读检查相邻 XMP 证据…"))
          assetBuild = try await Self.addingSidecarEvidence(to: assetBuild, client: client)
          guard !assetBuild.assets.isEmpty else {
            throw WorkflowFailure(message: "没有照片包含可解析的原始拍摄时间。")
          }
          let writableAssets = assetBuild.assets.filter { $0.rawFile != nil }
          guard !writableAssets.isEmpty else {
            throw WorkflowFailure(message: "没有发现可生成 XMP sidecar 的专有 RAW（NEF、ARW 等）。")
          }

          continuation.yield(.progress(fraction: 0.44, message: "流式读取并独立规范化 GPX 来源…"))
          try Task.checkCancellation()
          let gpxFiles = try Self.gpxFiles(in: gpxDirectoryURL)
          guard !gpxFiles.isEmpty else {
            throw WorkflowFailure(message: "所选目录中没有 GPX 文件。")
          }
          let trackBuild = try Self.makeTrajectorySources(gpxFiles: gpxFiles)

          continuation.yield(.progress(fraction: 0.62, message: "重建活动、相机与缺轨会话…"))
          try Task.checkCancellation()
          var trajectorySources = trackBuild.sources
          if let embeddedSource = EmbeddedFixTrajectoryBuilder(
            normalizer: Self.v2TrackNormalizer()
          ).makeSource(
            id: "embedded-fixes",
            displayName: "相机 GPSDateTime 定位事件",
            priority: 200,
            observations: assetBuild.observations
          ) {
            trajectorySources.append(embeddedSource)
          }
          let corpus = TrajectoryCorpusBuilder().build(sources: trajectorySources)
          let regions =
            configuration.matchingStrategy == .coverage
            ? Self.makeActivityRegions(
              assets: assetBuild.assets.map(\.asset),
              sources: trackBuild.sources,
              timeZone: configuration.timeZone
            ) : []

          continuation.yield(.progress(fraction: 0.80, message: "按来源强度生成并解决候选…"))
          let engine = DeterministicLocationEngine(
            matcherConfiguration: GeoMatcherConfiguration(
              exactToleranceSeconds: 2,
              nearestToleranceSeconds: 120,
              agreeingCandidateDistanceMeters: 150
            )
          )
          let resolutions = engine.resolve(
            LocationInferenceInput(
              assets: assetBuild.assets.map(\.asset),
              trajectoryCorpus: corpus,
              observations: assetBuild.observations,
              assetRelations: assetBuild.relations,
              activityRegions: regions
            )
          )
          let resolutionByID = Dictionary(
            uniqueKeysWithValues: resolutions.map { ($0.assetID, $0) }
          )
          let matches = writableAssets.compactMap { prepared -> PhotoMatch? in
            guard let rawFile = prepared.rawFile,
              let resolution = resolutionByID[prepared.asset.id]
            else { return nil }
            return Self.makePhotoMatchV2(
              resolution: resolution,
              prepared: prepared,
              file: rawFile,
              strategy: configuration.matchingStrategy,
              writeAltitude: configuration.writeAltitude,
              trackSourceDigests: trackBuild.sourceDigests
            )
          }
          .sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
          }
          let trackCoordinates = Self.visibleTrackCoordinatesV2(
            sources: trackBuild.sources,
            captureDates: writableAssets.map { $0.asset.captureTimeUTC }
          )
          let clockSuggestions = Self.makeClockSuggestions(from: assetBuild)

          continuation.yield(.progress(fraction: 1, message: "分析完成"))
          continuation.yield(
            .completed(
              AnalysisSnapshot(
                matches: matches,
                trackCoordinates: trackCoordinates,
                warnings: mediaRead.warnings + assetBuild.warnings + trackBuild.warnings,
                clockSuggestions: clockSuggestions
              )
            )
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

  private static func photoFiles(in directory: URL) throws -> [ReadOnlyMediaFile] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      throw WorkflowFailure(message: "无法读取照片目录。")
    }
    let urls = enumerator.compactMap { $0 as? URL }
    return
      try urls
      .filter { ReadOnlyMediaFile.supportedExtensions.contains($0.pathExtension.lowercased()) }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
      .map(ReadOnlyMediaFile.init(url:))
  }

  private static func readMediaMetadataInBatches(
    client: ExifToolClient,
    files: [ReadOnlyMediaFile],
    batchSize: Int,
    progress: (Int, Int) -> Void
  ) async throws -> (metadata: [MediaMetadata], warnings: [String]) {
    precondition(batchSize > 0)
    var result: [MediaMetadata] = []
    var warnings: [String] = []
    result.reserveCapacity(files.count)
    var start = 0
    while start < files.count {
      try Task.checkCancellation()
      let end = min(start + batchSize, files.count)
      let batch = try await readMediaMetadataResilient(
        client: client,
        files: Array(files[start..<end])
      )
      result.append(contentsOf: batch.metadata)
      warnings.append(contentsOf: batch.warnings)
      start = end
      progress(start, files.count)
    }
    return (result, warnings)
  }

  private static func readMediaMetadataResilient(
    client: ExifToolClient,
    files: [ReadOnlyMediaFile]
  ) async throws -> (metadata: [MediaMetadata], warnings: [String]) {
    do {
      return (try await client.readMediaMetadata(files), [])
    } catch {
      try Task.checkCancellation()
      if let metadataError = error as? MetadataInfrastructureError,
        case .cancelled = metadataError
      {
        throw CancellationError()
      }
      guard files.count > 1 else {
        let name = files.first?.url.lastPathComponent ?? "未知文件"
        return ([], ["\(name) 的元数据读取失败，已跳过该文件"])
      }
      let middle = files.count / 2
      let left = try await readMediaMetadataResilient(
        client: client,
        files: Array(files[..<middle])
      )
      let right = try await readMediaMetadataResilient(
        client: client,
        files: Array(files[middle...])
      )
      return (
        left.metadata + right.metadata,
        left.warnings + right.warnings
      )
    }
  }

  private static func gpxFiles(in directory: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      throw WorkflowFailure(message: "无法读取 GPX 目录。")
    }
    return enumerator.compactMap { element -> URL? in
      guard let url = element as? URL, url.pathExtension.lowercased() == "gpx" else {
        return nil
      }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true
      else { return nil }
      return url.standardizedFileURL
    }
    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  private struct PreparedAsset: Sendable {
    let asset: CaptureAsset
    let metadata: MediaMetadata
    let rawFile: ReadOnlyRawFile?
  }

  private struct AssetBuild: Sendable {
    let assets: [PreparedAsset]
    let observations: [AssetLocationObservation]
    let relations: [AssetRelation]
    let clockReferences: [ClockReferenceObservation]
    let warnings: [String]
  }

  private struct TrackBuild: Sendable {
    let sources: [TrajectoryLogicalSource]
    let sourceDigests: [String: String]
    let warnings: [String]
  }

  private static func makeAssets(
    metadata: [MediaMetadata],
    photoRootURL: URL,
    timeZoneIdentifier: String,
    globalCameraClockDelta: TimeInterval,
    cameraClockOffsetsByID: [String: Int]
  ) -> AssetBuild {
    var prepared: [PreparedAsset] = []
    var observations: [AssetLocationObservation] = []
    var clockReferences: [ClockReferenceObservation] = []
    var warnings: [String] = []

    for item in metadata {
      guard let original = item.dateTimeOriginal else {
        warnings.append("\(item.mediaFile.url.lastPathComponent) 缺少 DateTimeOriginal")
        continue
      }
      do {
        let camera = cameraIdentity(for: item)
        let cameraDelta = TimeInterval(
          cameraClockOffsetsByID[camera.id.rawValue]
            ?? Int(globalCameraClockDelta.rounded())
        )
        let timestamp = try parsePhotoTimestamp(
          original,
          subsecond: item.subsecondTimeOriginal,
          offset: item.offsetTimeOriginal
        )
        let captureUTC = try TimeNormalizer().normalize(
          timestamp,
          timeZoneIdentifier: timeZoneIdentifier,
          cameraClockDelta: cameraDelta
        )
        let activityID = activityID(
          for: item.mediaFile.url,
          root: photoRootURL,
          captureUTC: captureUTC,
          timeZoneIdentifier: timeZoneIdentifier
        )
        let assetID = CaptureAssetID(rawValue: item.mediaFile.url.path)
        let asset = CaptureAsset(
          id: assetID,
          relativePath: relativePath(of: item.mediaFile.url, under: photoRootURL),
          kind: assetKind(for: item),
          activityID: activityID,
          camera: camera,
          captureTimeUTC: captureUTC,
          captureTimePrecision: hasSubsecond(item.subsecondTimeOriginal) ? .subsecond : .second,
          sequenceNumber: sequenceNumber(from: item.mediaFile.url),
          shutterCount: item.shutterCount
        )
        let rawFile = try? ReadOnlyRawFile(mediaFile: item.mediaFile)
        prepared.append(PreparedAsset(asset: asset, metadata: item, rawFile: rawFile))

        if let gps = item.gps {
          let gpsTimestamp = parseGPSTimestamp(item.gpsDateTime)
          let observationKind = observationKind(for: item)
          let observation = AssetLocationObservation(
            id: "metadata:\(assetID.rawValue)",
            assetID: assetID,
            coordinate: RawGeoCore.GeoCoordinate(
              latitude: gps.latitude,
              longitude: gps.longitude
            ),
            elevationMeters: gps.altitude,
            observedAtUTC: captureUTC,
            gpsTimestampUTC: gpsTimestamp,
            horizontalAccuracyMeters: item.gpsHorizontalPositioningError,
            kind: observationKind,
            isCircular: observationKind == .renderedDerivative
          )
          observations.append(observation)

          // 只有直接传感器且 fix 与快门接近时，才足以形成时钟“建议”；
          // Nikon 的 GPSDateTime 常是陈旧 fix，不能把 fix age 误当时钟偏差。
          if observationKind == .directSensor,
            let gpsTimestamp,
            abs(captureUTC.timeIntervalSince(gpsTimestamp)) <= 60
          {
            clockReferences.append(
              ClockReferenceObservation(
                id: observation.id,
                assetID: assetID,
                cameraID: camera.id,
                cameraCaptureTimeUTC: captureUTC,
                referenceTimeUTC: gpsTimestamp,
                kind: .directGPS,
                referenceAccuracySeconds: item.gpsHorizontalPositioningError
              )
            )
          }
        }
      } catch {
        warnings.append("\(item.mediaFile.url.lastPathComponent) 的拍摄时间无法解析")
      }
    }

    let sorted = prepared.sorted {
      if $0.asset.captureTimeUTC != $1.asset.captureTimeUTC {
        return $0.asset.captureTimeUTC < $1.asset.captureTimeUTC
      }
      return $0.asset.id.rawValue < $1.asset.id.rawValue
    }
    return AssetBuild(
      assets: sorted,
      observations: observations.sorted { $0.id < $1.id },
      relations: makeAssetRelations(sorted),
      clockReferences: clockReferences.sorted { $0.id < $1.id },
      warnings: warnings
    )
  }

  private static func addingSidecarEvidence(
    to build: AssetBuild,
    client: ExifToolClient
  ) async throws -> AssetBuild {
    var observations = build.observations
    var warnings = build.warnings
    let sidecarsByRawURL = try makeSidecarIndex(
      for: build.assets.compactMap(\.rawFile),
      warnings: &warnings
    )
    for prepared in build.assets {
      try Task.checkCancellation()
      guard let rawFile = prepared.rawFile else { continue }
      do {
        guard let sidecar = sidecarsByRawURL[rawFile.url.standardizedFileURL] else { continue }
        let metadata = try await client.readSidecarMetadata(at: sidecar)
        guard let gps = metadata.gps else { continue }
        observations.append(
          AssetLocationObservation(
            id: "sidecar:\(prepared.asset.id.rawValue)",
            assetID: prepared.asset.id,
            coordinate: RawGeoCore.GeoCoordinate(
              latitude: gps.latitude,
              longitude: gps.longitude
            ),
            elevationMeters: gps.altitude,
            observedAtUTC: prepared.asset.captureTimeUTC,
            kind: .sidecar,
            // Sidecar 可能来自 RawGeoSync 自己的上一轮推断；缺少独立来源证明时
            // 只能作为循环、待确认的候选，不能压过 GPX 或传感器锚点。
            isCircular: true
          )
        )
      } catch let metadataError as MetadataInfrastructureError {
        if case .cancelled = metadataError { throw CancellationError() }
        warnings.append("\(rawFile.url.lastPathComponent) 的相邻 XMP 无法作为证据读取")
      } catch {
        warnings.append("\(rawFile.url.lastPathComponent) 的相邻 XMP 无法作为证据读取")
      }
    }
    return AssetBuild(
      assets: build.assets,
      observations: observations.sorted { $0.id < $1.id },
      relations: build.relations,
      clockReferences: build.clockReferences,
      warnings: warnings
    )
  }

  private static func makeSidecarIndex(
    for rawFiles: [ReadOnlyRawFile],
    warnings: inout [String]
  ) throws -> [URL: SidecarURL] {
    let fileManager = FileManager.default
    let rawFilesByDirectory = Dictionary(grouping: rawFiles) {
      $0.url.deletingLastPathComponent().standardizedFileURL
    }
    var result: [URL: SidecarURL] = [:]

    for directory in rawFilesByDirectory.keys.sorted(by: { $0.path < $1.path }) {
      try Task.checkCancellation()
      let entries = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
      let sidecarsByStem = Dictionary(
        grouping: entries.filter {
          $0.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame
        }
      ) {
        $0.deletingPathExtension().lastPathComponent.lowercased()
      }

      for rawFile in rawFilesByDirectory[directory, default: []] {
        let stem = rawFile.url.deletingPathExtension().lastPathComponent.lowercased()
        let candidates = sidecarsByStem[stem, default: []]
        guard candidates.count <= 1 else {
          warnings.append("\(rawFile.url.lastPathComponent) 同时存在多个大小写不同的 XMP，已跳过")
          continue
        }
        guard let candidate = candidates.first else { continue }
        do {
          result[rawFile.url.standardizedFileURL] = try SidecarURL(existingURL: candidate)
        } catch {
          warnings.append("\(rawFile.url.lastPathComponent) 的相邻 XMP 不是安全的普通文件，已跳过")
        }
      }
    }
    return result
  }

  private static func makeTrajectorySources(gpxFiles: [URL]) throws -> TrackBuild {
    let normalizer = v2TrackNormalizer()
    var sources: [TrajectoryLogicalSource] = []
    var sourceDigests: [String: String] = [:]
    var warnings: [String] = []
    for (index, url) in gpxFiles.enumerated() {
      let document = try GPXStreamParser().parse(url: url)
      let track = normalizer.normalize(document)
      if !document.warnings.isEmpty || !track.warnings.isEmpty {
        warnings.append(
          "\(url.lastPathComponent)：解析警告 \(document.warnings.count) 项，轨迹规范化警告 \(track.warnings.count) 项"
        )
      }
      let sourceID = TrajectorySourceID(rawValue: "gpx-\(index)-\(url.lastPathComponent)")
      sources.append(
        TrajectoryLogicalSource(
          id: sourceID,
          displayName: url.lastPathComponent,
          kind: .gpx,
          priority: 100,
          track: track
        )
      )
      sourceDigests[sourceID.rawValue] = try sha256(of: url)
    }
    return TrackBuild(sources: sources, sourceDigests: sourceDigests, warnings: warnings)
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = handle.readData(ofLength: 256 * 1_024)
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func v2TrackNormalizer() -> TrackNormalizer {
    TrackNormalizer(
      configuration: TrackNormalizationConfiguration(
        duplicateCoordinateToleranceMeters: 30,
        reliableMaximumDurationSeconds: 60,
        reliableMaximumDistanceMeters: 250,
        reviewMaximumDurationSeconds: 600,
        stayMinimumDurationSeconds: 600,
        stayMaximumDurationSeconds: 21_600,
        stayMaximumDisplacementMeters: 150,
        maximumImpliedSpeedMetersPerSecond: 500,
        spikeMaximumLegDurationSeconds: 120,
        spikeMinimumLegDistanceMeters: 500,
        spikeMaximumDirectDistanceMeters: 100,
        spikeMaximumDirectDistanceRatio: 0.1
      )
    )
  }

  private static func cameraIdentity(for metadata: MediaMetadata) -> CameraIdentity {
    let optionalComponents: [String?] = [
      metadata.make,
      metadata.model,
      metadata.serialNumber ?? metadata.internalSerialNumber,
    ]
    let components = optionalComponents.compactMap { $0 }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let fallback = metadata.mediaFile.url.deletingLastPathComponent().lastPathComponent
    let id = components.isEmpty ? fallback : components.joined(separator: "|")
    return CameraIdentity(
      id: CameraID(rawValue: id),
      make: metadata.make,
      model: metadata.model,
      serialNumber: metadata.serialNumber,
      internalSerialNumber: metadata.internalSerialNumber
    )
  }

  private static func assetKind(for metadata: MediaMetadata) -> CaptureAssetKind {
    switch metadata.mediaFile.kind {
    case .proprietaryRaw:
      return .raw
    case .dng:
      let model = metadata.model?.lowercased() ?? ""
      let isOriginalPhone = model.contains("iphone") && metadata.derivedFrom == nil
      return isOriginalPhone ? .originalDNG : .derivedDNG
    case .jpeg, .tiff:
      return .rendered
    }
  }

  private static func observationKind(for metadata: MediaMetadata)
    -> AssetLocationObservationKind
  {
    switch metadata.mediaFile.kind {
    case .jpeg, .tiff:
      return .renderedDerivative
    case .dng where metadata.model?.localizedCaseInsensitiveContains("iPhone") == true:
      return .directSensor
    case .dng, .proprietaryRaw:
      return .cameraEmbedded
    }
  }

  private struct SameAssetKey: Hashable {
    let activityID: ActivityID?
    let cameraID: CameraID?
    let captureSecond: Int64
    let token: String
  }

  private static func makeAssetRelations(_ assets: [PreparedAsset]) -> [AssetRelation] {
    let groups = Dictionary(grouping: assets) { prepared in
      SameAssetKey(
        activityID: prepared.asset.activityID,
        cameraID: prepared.asset.camera?.id,
        captureSecond: Int64(prepared.asset.captureTimeUTC.timeIntervalSince1970.rounded(.down)),
        token: assetToken(for: prepared.metadata.mediaFile.url)
      )
    }
    var relations: [AssetRelation] = []
    for group in groups.values {
      let targets = group.filter { $0.rawFile != nil }
      let evidenceAssets = group.filter { $0.rawFile == nil }
      for target in targets {
        for evidence in evidenceAssets where evidence.asset.id != target.asset.id {
          relations.append(
            AssetRelation(
              id: "same:\(evidence.asset.id.rawValue)>\(target.asset.id.rawValue)",
              sourceAssetID: evidence.asset.id,
              targetAssetID: target.asset.id,
              kind: .derivedFrom
            )
          )
        }
      }
    }
    return relations.sorted { $0.id < $1.id }
  }

  private static func makeActivityRegions(
    assets: [CaptureAsset],
    sources: [TrajectoryLogicalSource],
    timeZone: TimeZone
  ) -> [ActivityRegion] {
    let points = sources.flatMap { $0.track.segments.flatMap(\.points) }
      .sorted { $0.timestamp < $1.timestamp }
    let grouped = Dictionary(
      grouping: assets.compactMap { asset -> CaptureAsset? in
        asset.activityID == nil ? nil : asset
      }, by: { $0.activityID! })
    var regions: [ActivityRegion] = []

    for activityID in grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      let activityAssets = grouped[activityID, default: []].sorted {
        if $0.captureTimeUTC != $1.captureTimeUTC {
          return $0.captureTimeUTC < $1.captureTimeUTC
        }
        return $0.id.rawValue < $1.id.rawValue
      }
      let sessions = photoSessions(activityAssets, maximumGapSeconds: 30 * 60)
      for (sessionIndex, session) in sessions.enumerated() {
        guard let minimum = session.first?.captureTimeUTC,
          let maximum = session.last?.captureTimeUTC
        else { continue }
        let lower = minimum.addingTimeInterval(-3_600)
        let upper = maximum.addingTimeInterval(3_600)
        let nearby = points.filter { $0.timestamp >= lower && $0.timestamp <= upper }
        var representative = representativeRegion(from: nearby)
        var label = "照片会话前后 1 小时 GPX 的稳健代表位置"

        if representative == nil || representative!.radiusMeters > 150_000 {
          var calendar = Calendar(identifier: .gregorian)
          calendar.timeZone = timeZone
          let sameDayGroundPoints = points.filter { point in
            calendar.isDate(point.timestamp, inSameDayAs: minimum)
              && point.speedMetersPerSecond.map { $0 < 80 } != false
          }
          let midpoint = minimum.addingTimeInterval(
            maximum.timeIntervalSince(minimum) / 2)
          if let nearest = sameDayGroundPoints.min(by: {
            abs($0.timestamp.timeIntervalSince(midpoint))
              < abs($1.timestamp.timeIntervalSince(midpoint))
          }) {
            let localCluster = sameDayGroundPoints.filter {
              RawGeoCore.GeoMath.distance(from: nearest.coordinate, to: $0.coordinate) <= 50_000
            }
            if let fallback = representativeRegion(from: localCluster) {
              representative = (
                fallback.coordinate,
                max(10_000, fallback.radiusMeters)
              )
              label = "同一当地日、时间最近的非飞行城市定位簇（粗略）"
            }
          }
        }

        if representative == nil,
          let before = points.last(where: { $0.timestamp < minimum }),
          let after = points.first(where: { $0.timestamp > maximum }),
          minimum.timeIntervalSince(before.timestamp) <= 36 * 3_600,
          after.timestamp.timeIntervalSince(maximum) <= 36 * 3_600,
          RawGeoCore.GeoMath.distance(from: before.coordinate, to: after.coordinate) <= 1_000,
          let fallback = representativeRegion(from: [before, after])
        {
          representative = (fallback.coordinate, max(10_000, fallback.radiusMeters))
          label = "前后相邻日同地点定位簇（粗略）"
        }

        guard let representative, representative.radiusMeters <= 150_000 else { continue }
        regions.append(
          ActivityRegion(
            id: "region:\(activityID.rawValue):session-\(sessionIndex)",
            activityID: activityID,
            coordinate: representative.coordinate,
            radiusMeters: representative.radiusMeters,
            source: .learned,
            label: label,
            activeFromUTC: minimum,
            activeToUTC: maximum
          )
        )
      }
    }
    return regions
  }

  private static func photoSessions(
    _ sortedAssets: [CaptureAsset],
    maximumGapSeconds: TimeInterval
  ) -> [[CaptureAsset]] {
    var sessions: [[CaptureAsset]] = []
    for asset in sortedAssets {
      if let previous = sessions.last?.last,
        asset.captureTimeUTC.timeIntervalSince(previous.captureTimeUTC) <= maximumGapSeconds
      {
        sessions[sessions.count - 1].append(asset)
      } else {
        sessions.append([asset])
      }
    }
    return sessions
  }

  private static func representativeRegion(from points: [TrackPoint])
    -> (coordinate: RawGeoCore.GeoCoordinate, radiusMeters: Double)?
  {
    guard !points.isEmpty else { return nil }
    let latitudes = points.map(\.coordinate.latitude).sorted()
    let longitudes = points.map(\.coordinate.longitude).sorted()
    let center = RawGeoCore.GeoCoordinate(
      latitude: median(latitudes),
      longitude: median(longitudes)
    )
    let representative =
      points.min {
        RawGeoCore.GeoMath.distance(from: $0.coordinate, to: center)
          < RawGeoCore.GeoMath.distance(from: $1.coordinate, to: center)
      }?.coordinate ?? center
    let distances = points.map {
      RawGeoCore.GeoMath.distance(from: representative, to: $0.coordinate)
    }.sorted()
    let p90Index = min(distances.count - 1, Int((Double(distances.count - 1) * 0.9).rounded()))
    return (representative, max(1, distances[p90Index]))
  }

  private static func median(_ sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2
      : sorted[middle]
  }

  private static func makeClockSuggestions(from build: AssetBuild) -> [ClockSuggestionInfo] {
    var labels: [CameraID: String] = [:]
    for prepared in build.assets {
      guard let camera = prepared.asset.camera else { continue }
      labels[camera.id] = camera.model ?? camera.id.rawValue
    }
    return ClockSuggestionEngine().suggest(from: build.clockReferences).compactMap { suggestion in
      let seconds = Int(suggestion.cameraAheadBySeconds.rounded())
      guard abs(seconds) >= 2 else { return nil }
      return ClockSuggestionInfo(
        cameraID: suggestion.cameraID.rawValue,
        cameraLabel: labels[suggestion.cameraID] ?? suggestion.cameraID.rawValue,
        cameraAheadBySeconds: seconds,
        evidenceCount: suggestion.evidenceCount,
        residualSeconds: suggestion.medianAbsoluteResidualSeconds,
        confidenceLabel: suggestion.confidence.rawValue
      )
    }
  }

  private static func activityID(
    for fileURL: URL,
    root: URL,
    captureUTC: Date,
    timeZoneIdentifier: String
  ) -> ActivityID {
    let relative = relativePath(of: fileURL, under: root)
    let components = relative.split(separator: "/").map(String.init)
    let rootName = root.lastPathComponent
    let base: String
    if looksLikeActivityFolder(rootName) {
      base = rootName
    } else if let first = components.first, components.count > 1 {
      base = first
    } else {
      let parentName = root.deletingLastPathComponent().lastPathComponent
      base = looksLikeActivityFolder(parentName) ? parentName : rootName
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
    formatter.dateFormat = "yyyy-MM-dd"
    return ActivityID(rawValue: "\(base)|\(formatter.string(from: captureUTC))")
  }

  private static func looksLikeActivityFolder(_ name: String) -> Bool {
    name.range(of: #"^20\d{2}[-.]\d{1,2}[-.]\d{1,2}"#, options: .regularExpression) != nil
  }

  private static func relativePath(of fileURL: URL, under root: URL) -> String {
    let rootPath = root.standardizedFileURL.path.trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    let filePath = fileURL.standardizedFileURL.path
    let prefix = "/\(rootPath)/"
    if filePath.hasPrefix(prefix) {
      return String(filePath.dropFirst(prefix.count))
    }
    return fileURL.lastPathComponent
  }

  private static func hasSubsecond(_ value: String?) -> Bool {
    value?.contains(where: \Character.isNumber) == true
  }

  private static func sequenceNumber(from url: URL) -> Int? {
    let stem = url.deletingPathExtension().lastPathComponent
    guard let match = stem.range(of: #"\d{3,}$"#, options: .regularExpression) else {
      return nil
    }
    return Int(stem[match])
  }

  private static func assetToken(for url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent.uppercased()
    if let match = stem.range(
      of: #"(?:DSC|IMG|DSCF|DSCN|NZ5|NZ50|A6400|A7CII)[_-]?\d{3,}"#,
      options: .regularExpression
    ),
      let digits = stem[match].range(of: #"\d{3,}$"#, options: .regularExpression)
    {
      return "SEQUENCE-\(stem[match][digits])"
    }
    return stem
  }

  private static func parseGPSTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .gmt
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
    if let date = formatter.date(from: value) { return date }
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss'Z'"
    return formatter.date(from: value)
  }

  private static func combinedDocument(_ documents: [GPXDocument]) -> GPXDocument {
    var segments: [GPXTrackSegment] = []
    var warnings: [GPXWarning] = []
    for (documentIndex, document) in documents.enumerated() {
      warnings.append(contentsOf: document.warnings)
      for segment in document.segments {
        let trackIndex = documentIndex * 100_000 + segment.trackIndex
        let points = segment.points.map { point in
          TrackPoint(
            timestamp: point.timestamp,
            coordinate: point.coordinate,
            elevationMeters: point.elevationMeters,
            horizontalAccuracyMeters: point.horizontalAccuracyMeters,
            speedMetersPerSecond: point.speedMetersPerSecond,
            courseDegrees: point.courseDegrees,
            source: TrackPointSource(
              trackIndex: trackIndex,
              segmentIndex: segment.segmentIndex,
              pointIndex: point.source.pointIndex
            )
          )
        }
        segments.append(
          GPXTrackSegment(
            trackIndex: trackIndex,
            segmentIndex: segment.segmentIndex,
            points: points
          )
        )
      }
    }
    return GPXDocument(
      version: "combined", creator: "RawGeoSync", segments: segments, warnings: warnings)
  }

  private static func makeCaptures(
    metadata: [RawPhotoMetadata],
    timeZoneIdentifier: String,
    cameraClockDelta: TimeInterval
  ) -> (
    captures: [(capture: PhotoCapture, file: ReadOnlyRawFile)], warnings: [String]
  ) {
    var captures: [(capture: PhotoCapture, file: ReadOnlyRawFile)] = []
    var warnings: [String] = []
    for item in metadata {
      guard let original = item.dateTimeOriginal else {
        warnings.append("\(item.rawFile.url.lastPathComponent) 缺少 DateTimeOriginal")
        continue
      }
      do {
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
        captures.append(
          (
            PhotoCapture(id: item.rawFile.url.path, captureTimeUTC: utc),
            item.rawFile
          )
        )
      } catch {
        warnings.append("\(item.rawFile.url.lastPathComponent) 的拍摄时间无法解析")
      }
    }
    return (captures, warnings)
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

  private static func makePhotoMatchV2(
    resolution: LocationResolution,
    prepared: PreparedAsset,
    file: ReadOnlyRawFile,
    strategy: MatchingStrategy,
    writeAltitude: Bool,
    trackSourceDigests: [String: String]
  ) -> PhotoMatch {
    let coverageFallback =
      strategy == .coverage && resolution.selectedCandidate == nil
      ? resolution.candidates.first(where: { $0.sourceKind == .activityRegion }) : nil
    let candidate = resolution.selectedCandidate ?? coverageFallback
    let usesConflictRegionFallback = coverageFallback != nil
    let evidenceCoordinates = candidate?.evidence.compactMap(\.coordinate) ?? []
    let previous = evidenceCoordinates.first.map(appCoordinate)
    let next = evidenceCoordinates.dropFirst().first.map(appCoordinate)
    let allowAltitude =
      candidate.map {
        writeAltitude && ($0.granularity == .exact || $0.granularity == .precise)
      } ?? false
    let coordinate = candidate.map {
      GeoCoordinate(
        latitude: $0.coordinate.latitude,
        longitude: $0.coordinate.longitude,
        altitude: allowAltitude ? $0.elevationMeters : nil
      )
    }
    let confidence =
      usesConflictRegionFallback
      ? MatchConfidence.coarse
      : appConfidence(resolution: resolution, candidate: candidate)
    let method = candidate.map { appMethod($0.sourceKind) } ?? .unavailable
    let granularity =
      candidate.map { appGranularity($0.sourceKind, $0.granularity) }
      ?? .unavailable
    let actualAccuracy = candidate?.evidence.compactMap(\.horizontalAccuracyMeters).min()
    let sourceAccuracy: SourceLocationAccuracy =
      actualAccuracy.map(SourceLocationAccuracy.meters)
      ?? .notProvided
    let evidenceTimes = candidate?.evidence.compactMap(\.observedAtUTC).sorted() ?? []
    let trackFileSHA256 = candidate?.evidence.compactMap { evidence in
      evidence.sourceID.flatMap { trackSourceDigests[$0] }
    }.first
    let temporalDistance = evidenceTimes.map {
      abs($0.timeIntervalSince(prepared.asset.captureTimeUTC))
    }.min()
    let xmpURL = file.url.deletingPathExtension().appendingPathExtension("xmp")
    let hasAdjacentXMP = FileManager.default.fileExists(atPath: xmpURL.path)
    let hasExistingGPS = prepared.metadata.gps != nil || hasAdjacentXMP
    let shouldAutomaticallyCheck =
      confidence == .reliable && coordinate != nil && !hasExistingGPS
    let evidenceSummary =
      candidate.map { selected in
        let kinds = Set(selected.evidence.map(\.kind.rawValue)).sorted().joined(separator: "+")
        return "\(selected.ruleID) · \(kinds)"
      } ?? resolution.reasons.map(\.rawValue).joined(separator: " · ")
    let confirmationGroupID = candidate.flatMap { selected -> String? in
      guard selected.requiresConfirmation else { return nil }
      let latitude = (selected.coordinate.latitude * 10_000).rounded() / 10_000
      let longitude = (selected.coordinate.longitude * 10_000).rounded() / 10_000
      return "\(selected.ruleID)|\(latitude)|\(longitude)"
    }

    return PhotoMatch(
      id: prepared.asset.id.rawValue,
      fileURL: file.url,
      capturedAt: prepared.asset.captureTimeUTC,
      previousTrackPoint: previous,
      nextTrackPoint: next,
      coordinate: coordinate,
      confidence: confidence,
      method: method,
      granularity: granularity,
      sourceLocationAccuracy: sourceAccuracy,
      evidenceSummary: evidenceSummary,
      supportSpreadMeters: candidate?.estimatedRadiusMeters,
      confirmationGroupID: confirmationGroupID,
      ruleVersion: resolution.ruleVersion,
      sourceTimeLowerBound: evidenceTimes.first,
      sourceTimeUpperBound: evidenceTimes.last,
      temporalDistanceSeconds: temporalDistance,
      trackFileSHA256: trackFileSHA256,
      note: matchNote(
        resolution: resolution,
        candidate: candidate,
        usesConflictRegionFallback: usesConflictRegionFallback,
        hasExistingGPS: hasExistingGPS,
        hasAdjacentXMP: hasAdjacentXMP
      ),
      isSelectedForWrite: shouldAutomaticallyCheck,
      isWritableTarget: true,
      hasExistingGPS: hasExistingGPS,
      hasProtectedExternalXMP: false
    )
  }

  private static func appConfidence(
    resolution: LocationResolution,
    candidate: LocationCandidate?
  ) -> MatchConfidence {
    guard let candidate else { return .unmatched }
    switch resolution.status {
    case .conflict, .unresolved:
      return .unmatched
    case .review:
      return candidate.granularity == .veryCoarse || candidate.sourceKind == .activityRegion
        ? .coarse : .review
    case .resolved:
      return candidate.granularity == .veryCoarse ? .coarse : .reliable
    }
  }

  private static func appGranularity(
    _ source: LocationSourceKind,
    _ granularity: LocationGranularity
  ) -> SpatialGranularity {
    switch source {
    case .manualOverride: return .manual
    case .directSensor, .embeddedFreshFix: return .sensor
    case .gpxExact, .gpxInterpolated, .embeddedTrackFix: return .track
    case .sameAsset, .burstPropagation, .sequencePropagation, .stationaryBounded,
      .crossCamera:
      return .photoCluster
    case .activityRegion:
      return granularity == .veryCoarse ? .region : .activity
    }
  }

  private static func appMethod(_ source: LocationSourceKind) -> MatchMethod {
    switch source {
    case .manualOverride: .manual
    case .directSensor, .embeddedFreshFix: .directSensor
    case .sameAsset: .sameAsset
    case .gpxExact: .exact
    case .gpxInterpolated: .interpolated
    case .embeddedTrackFix: .auxiliaryFix
    case .burstPropagation: .burstPropagation
    case .sequencePropagation: .sequencePropagation
    case .stationaryBounded: .stationary
    case .crossCamera: .crossCamera
    case .activityRegion: .activityRepresentative
    }
  }

  private static func matchNote(
    resolution: LocationResolution,
    candidate: LocationCandidate?,
    usesConflictRegionFallback: Bool = false,
    hasExistingGPS: Bool,
    hasAdjacentXMP: Bool
  ) -> String {
    if usesConflictRegionFallback {
      return "多个强来源位置相冲突；已提供活动区域粗略兜底，必须手动确认"
    }
    if resolution.status == .conflict {
      return "多个强来源位置相冲突，禁止自动写入"
    }
    guard let candidate else { return "没有足够证据形成位置候选" }
    var components: [String] = []
    if candidate.requiresConfirmation {
      components.append("该候选需要确认")
    } else {
      components.append("已按来源优先级自动选择")
    }
    if let radius = candidate.estimatedRadiusMeters {
      components.append("证据覆盖范围约 \(Int(radius.rounded())) 米（不是传感器精度）")
    }
    if hasAdjacentXMP {
      components.append("相邻 XMP 将在写入前做来源与摘要保护")
    } else if hasExistingGPS {
      components.append("文件已有 GPS，默认不替换")
    }
    return components.joined(separator: "；")
  }

  private static func visibleTrackCoordinatesV2(
    sources: [TrajectoryLogicalSource],
    captureDates: [Date]
  ) -> [GeoCoordinate] {
    guard let minimum = captureDates.min(), let maximum = captureDates.max() else { return [] }
    let lower = minimum.addingTimeInterval(-6 * 3_600)
    let upper = maximum.addingTimeInterval(6 * 3_600)
    let all = sources.flatMap { $0.track.segments.flatMap(\.points) }
      .filter { $0.timestamp >= lower && $0.timestamp <= upper }
      .sorted { $0.timestamp < $1.timestamp }
      .map(appCoordinate)
    guard all.count > 5_000 else { return all }
    let step = Int(ceil(Double(all.count) / 5_000.0))
    var result = stride(from: 0, to: all.count, by: step).map { all[$0] }
    if let last = all.last, result.last != last { result.append(last) }
    return result
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
      id: result.photo.id,
      fileURL: file.url,
      capturedAt: result.photo.captureTimeUTC,
      previousTrackPoint: previous,
      nextTrackPoint: next,
      coordinate: coordinate,
      confidence: existingGPS ? .review : confidence,
      method: appMethod(result.mode),
      granularity: result.coordinate == nil ? .unavailable : .track,
      sourceLocationAccuracy: sourceAccuracy,
      evidenceSummary: result.reasonCodes.map { String(describing: $0) }.joined(separator: " · "),
      supportSpreadMeters: firstCandidate.map {
        guard let end = $0.endPoint else { return 0 }
        return RawGeoCore.GeoMath.distance(from: $0.startPoint.coordinate, to: end.coordinate)
      },
      confirmationGroupID: result.mode == .stayCandidate
        ? "stay-\(firstCandidate?.segmentID ?? -1)-\(firstCandidate?.startPoint.timestamp.timeIntervalSince1970 ?? 0)"
        : nil,
      note: existingGPS ? "文件已有 GPS，默认跳过；重新勾选写入即表示明确替换" : note(result),
      isSelectedForWrite: confidence == .reliable && !existingGPS,
      isWritableTarget: true,
      hasExistingGPS: existingGPS,
      hasProtectedExternalXMP: false
    )
  }

  private static func appCoordinate(_ point: TrackPoint) -> GeoCoordinate {
    GeoCoordinate(
      latitude: point.coordinate.latitude,
      longitude: point.coordinate.longitude,
      altitude: point.elevationMeters
    )
  }

  private static func appCoordinate(_ coordinate: RawGeoCore.GeoCoordinate) -> GeoCoordinate {
    GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: nil)
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
      let policy: ExistingGPSPolicy
      if match.hasExistingGPS {
        policy = match.replacementExplicitlyAuthorized ? .replace : .replaceIfStrongerProvenance
      } else {
        policy = .skip
      }
      return SidecarWriteRequest(
        rawFile: raw,
        gps: gps,
        existingGPSPolicy: policy,
        matchProvenance: MatchProvenance(
          source: provenanceSource(for: match.method),
          verification: provenanceVerification(for: match),
          algorithmVersion: match.ruleVersion,
          trackFileSHA256: match.trackFileSHA256,
          sourceTimeLowerBound: match.sourceTimeLowerBound,
          sourceTimeUpperBound: match.sourceTimeUpperBound,
          temporalDistanceSeconds: match.temporalDistanceSeconds,
          horizontalAccuracyMeters: match.sourceLocationAccuracy.meters
        )
      )
    }
  }

  private static func provenanceSource(for method: MatchMethod) -> MatchProvenanceSource {
    switch method {
    case .manual: .manual
    case .exact, .directSensor, .sameAsset: .exactTrackPoint
    case .interpolated, .reviewInterpolation, .auxiliaryFix, .burstPropagation,
      .sequencePropagation, .crossCamera:
      .interpolatedTrack
    case .stationary, .activityRepresentative, .regionRepresentative, .previousPoint,
      .nextPoint, .midpoint:
      .stationaryCandidate
    case .nearest, .unavailable: .nearestTrackPoint
    }
  }

  private static func provenanceVerification(for match: PhotoMatch)
    -> MatchProvenanceVerification
  {
    if match.method == .manual { return .manual }
    if match.replacementExplicitlyAuthorized || match.confidence != .reliable {
      return .userConfirmed
    }
    return .automatic
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
