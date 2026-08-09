import CryptoKit
import Foundation

public enum ExistingGPSPolicy: String, Codable, Hashable, Sendable {
  case skip
  case replace
  case replaceIfStrongerProvenance
}

public enum MatchProvenanceSource: String, Codable, Hashable, Sendable {
  case nearestTrackPoint
  case stationaryCandidate
  case interpolatedTrack
  case exactTrackPoint
  case manual

  fileprivate var rank: Int {
    switch self {
    case .nearestTrackPoint: 0
    case .stationaryCandidate: 1
    case .interpolatedTrack: 2
    case .exactTrackPoint: 3
    case .manual: 4
    }
  }
}

public enum MatchProvenanceVerification: String, Codable, Hashable, Sendable {
  case automatic
  case userConfirmed
  case manual

  fileprivate var rank: Int {
    switch self {
    case .automatic: 0
    case .userConfirmed: 1
    case .manual: 2
    }
  }
}

/// 解释坐标如何产生，并提供可重复的强度比较。它存入事务，不写入未知外部 XMP。
public struct MatchProvenance: Hashable, Codable, Sendable {
  public let source: MatchProvenanceSource
  public let verification: MatchProvenanceVerification
  public let algorithmVersion: String
  public let trackFileSHA256: String?
  public let generatedAt: Date
  public let sourceTimeLowerBound: Date?
  public let sourceTimeUpperBound: Date?
  public let temporalDistanceSeconds: Double?
  public let horizontalAccuracyMeters: Double?

  public init(
    source: MatchProvenanceSource,
    verification: MatchProvenanceVerification,
    algorithmVersion: String,
    trackFileSHA256: String? = nil,
    generatedAt: Date = Date(),
    sourceTimeLowerBound: Date? = nil,
    sourceTimeUpperBound: Date? = nil,
    temporalDistanceSeconds: Double? = nil,
    horizontalAccuracyMeters: Double? = nil
  ) {
    self.source = source
    self.verification = verification
    self.algorithmVersion = algorithmVersion
    self.trackFileSHA256 = trackFileSHA256
    self.generatedAt = generatedAt
    self.sourceTimeLowerBound = sourceTimeLowerBound
    self.sourceTimeUpperBound = sourceTimeUpperBound
    self.temporalDistanceSeconds = temporalDistanceSeconds.flatMap {
      $0.isFinite ? $0 : nil
    }
    self.horizontalAccuracyMeters = horizontalAccuracyMeters.flatMap {
      $0.isFinite && $0 >= 0 ? $0 : nil
    }
  }

  public func isProvablyStronger(than other: MatchProvenance) -> Bool {
    if verification.rank != other.verification.rank {
      return verification.rank > other.verification.rank
    }
    if source.rank != other.source.rank {
      return source.rank > other.source.rank
    }
    switch (horizontalAccuracyMeters, other.horizontalAccuracyMeters) {
    case (let lhs?, let rhs?) where lhs != rhs:
      return lhs < rhs
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      break
    }
    switch (temporalDistanceSeconds, other.temporalDistanceSeconds) {
    case (let lhs?, let rhs?) where abs(lhs) != abs(rhs):
      return abs(lhs) < abs(rhs)
    case (.some, .none):
      return true
    default:
      return false
    }
  }
}

public enum ExistingGPSOrigin: String, Codable, Hashable, Sendable {
  case embeddedMedia
  case externalSidecar
  case rawGeoSyncTransaction
}

public struct SidecarWriteRequest: Hashable, Codable, Sendable {
  public let rawFile: ReadOnlyRawFile
  public let gps: GPSMetadata
  public let existingGPSPolicy: ExistingGPSPolicy
  public let matchProvenance: MatchProvenance?

  public init(
    rawFile: ReadOnlyRawFile,
    gps: GPSMetadata,
    existingGPSPolicy: ExistingGPSPolicy = .skip,
    matchProvenance: MatchProvenance? = nil
  ) {
    self.rawFile = rawFile
    self.gps = gps
    self.existingGPSPolicy = existingGPSPolicy
    self.matchProvenance = matchProvenance
  }
}

public struct FileFingerprint: Hashable, Codable, Sendable {
  public let byteCount: Int
  public let modificationTime: Date
  public let sha256: String?

  public init(byteCount: Int, modificationTime: Date, sha256: String?) {
    self.byteCount = byteCount
    self.modificationTime = modificationTime
    self.sha256 = sha256
  }

  static func capture(_ url: URL, includeDigest: Bool) throws -> FileFingerprint {
    let values = try url.resourceValues(forKeys: [
      .fileSizeKey,
      .contentModificationDateKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true else {
      throw MetadataInfrastructureError.notAFile(url)
    }
    guard values.isSymbolicLink != true else {
      throw MetadataInfrastructureError.symbolicLinkNotAllowed(url)
    }
    return FileFingerprint(
      byteCount: values.fileSize ?? 0,
      modificationTime: values.contentModificationDate ?? .distantPast,
      sha256: includeDigest ? try digest(of: url) : nil
    )
  }

  private static func digest(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = handle.readData(ofLength: 64 * 1_024)
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public enum SidecarWriteDisposition: Hashable, Codable, Sendable {
  case create
  case update
  case alreadyApplied
  case conflict(String)

  public var isWritable: Bool {
    switch self {
    case .create, .update: true
    case .alreadyApplied, .conflict: false
    }
  }
}

public struct SidecarWritePlanItem: Hashable, Codable, Sendable, Identifiable {
  public let id: UUID
  public let rawFile: ReadOnlyRawFile
  public let sidecar: SidecarURL
  public let desiredGPS: GPSMetadata
  public let disposition: SidecarWriteDisposition
  public let rawPrecondition: FileFingerprint
  public let sidecarPrecondition: FileFingerprint?
  public let originalNonGPSSemanticDigest: String?
  public let matchProvenance: MatchProvenance?
  public let existingGPS: GPSMetadata?
  public let existingGPSOrigin: ExistingGPSOrigin?
  public let existingMatchProvenance: MatchProvenance?
  public let provenanceTransactionID: UUID?

  public init(
    id: UUID = UUID(),
    rawFile: ReadOnlyRawFile,
    sidecar: SidecarURL,
    desiredGPS: GPSMetadata,
    disposition: SidecarWriteDisposition,
    rawPrecondition: FileFingerprint,
    sidecarPrecondition: FileFingerprint?,
    originalNonGPSSemanticDigest: String?,
    matchProvenance: MatchProvenance? = nil,
    existingGPS: GPSMetadata? = nil,
    existingGPSOrigin: ExistingGPSOrigin? = nil,
    existingMatchProvenance: MatchProvenance? = nil,
    provenanceTransactionID: UUID? = nil
  ) {
    self.id = id
    self.rawFile = rawFile
    self.sidecar = sidecar
    self.desiredGPS = desiredGPS
    self.disposition = disposition
    self.rawPrecondition = rawPrecondition
    self.sidecarPrecondition = sidecarPrecondition
    self.originalNonGPSSemanticDigest = originalNonGPSSemanticDigest
    self.matchProvenance = matchProvenance
    self.existingGPS = existingGPS
    self.existingGPSOrigin = existingGPSOrigin
    self.existingMatchProvenance = existingMatchProvenance
    self.provenanceTransactionID = provenanceTransactionID
  }
}

public struct SidecarWritePlan: Hashable, Codable, Sendable, Identifiable {
  public let id: UUID
  public let createdAt: Date
  public let items: [SidecarWritePlanItem]

  public init(id: UUID = UUID(), createdAt: Date = Date(), items: [SidecarWritePlanItem]) {
    self.id = id
    self.createdAt = createdAt
    self.items = items
  }
}

public enum TransactionStatus: String, Codable, Hashable, Sendable {
  case applying
  case completed
  case completedWithFailures
  case cancelled
  case undoing
  case undone
  case undoFailed
}

public enum TransactionFileStatus: String, Codable, Hashable, Sendable {
  case pending
  case skipped
  case applying
  case applied
  case failed
  case undone
}

public struct TransactionFileRecord: Hashable, Codable, Sendable, Identifiable {
  public let id: UUID
  public let planItem: SidecarWritePlanItem
  public var status: TransactionFileStatus
  public var backupRelativePath: String?
  public var postWriteFingerprint: FileFingerprint?
  public var failureDescription: String?

  public init(planItem: SidecarWritePlanItem) {
    self.id = planItem.id
    self.planItem = planItem
    self.status = planItem.disposition.isWritable ? .pending : .skipped
  }
}

public struct XMPTransactionManifest: Hashable, Codable, Sendable, Identifiable {
  public static let currentSchemaVersion = 2

  public let schemaVersion: Int
  public let id: UUID
  public let createdAt: Date
  public var updatedAt: Date
  public var status: TransactionStatus
  public var records: [TransactionFileRecord]

  public init(plan: SidecarWritePlan, now: Date = Date()) {
    self.schemaVersion = Self.currentSchemaVersion
    self.id = plan.id
    self.createdAt = plan.createdAt
    self.updatedAt = now
    self.status = .applying
    self.records = plan.items.map(TransactionFileRecord.init)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, id, createdAt, updatedAt, status, records
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    self.id = try container.decode(UUID.self, forKey: .id)
    self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    self.status = try container.decode(TransactionStatus.self, forKey: .status)
    self.records = try container.decode([TransactionFileRecord].self, forKey: .records)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
    try container.encode(id, forKey: .id)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(status, forKey: .status)
    try container.encode(records, forKey: .records)
  }
}

public struct TransactionApplyReport: Hashable, Codable, Sendable {
  public let transactionID: UUID
  public let appliedCount: Int
  public let failedCount: Int
  public let skippedCount: Int
  public let wasCancelled: Bool

  public init(
    transactionID: UUID,
    appliedCount: Int,
    failedCount: Int,
    skippedCount: Int,
    wasCancelled: Bool
  ) {
    self.transactionID = transactionID
    self.appliedCount = appliedCount
    self.failedCount = failedCount
    self.skippedCount = skippedCount
    self.wasCancelled = wasCancelled
  }
}

public struct BackupCleanupReport: Hashable, Codable, Sendable {
  public let removedTransactionIDs: [UUID]
  public let retainedTransactionIDs: [UUID]

  public init(removedTransactionIDs: [UUID], retainedTransactionIDs: [UUID]) {
    self.removedTransactionIDs = removedTransactionIDs
    self.retainedTransactionIDs = retainedTransactionIDs
  }
}

private struct ProvenanceProof: Sendable {
  let transactionID: UUID
  let provenance: MatchProvenance
}

public actor XMPTransactionCoordinator {
  private let metadataTool: any MetadataTooling
  private let backupRoot: URL
  private let fileManager: FileManager

  public init(
    metadataTool: any MetadataTooling,
    backupRoot: URL,
    fileManager: FileManager = .default
  ) {
    self.metadataTool = metadataTool
    self.backupRoot = backupRoot.standardizedFileURL
    self.fileManager = fileManager
  }

  /// 只读预检。此方法不会创建目录、临时文件或清单。
  public func makeWritePlan(_ requests: [SidecarWriteRequest]) async throws -> SidecarWritePlan {
    let rawMetadata = try await metadataTool.readRawMetadata(requests.map(\.rawFile))
    let metadataByURL = Dictionary(uniqueKeysWithValues: rawMetadata.map { ($0.rawFile.url, $0) })
    let priorManifests = provenanceManifests()
    var items: [SidecarWritePlanItem] = []
    items.reserveCapacity(requests.count)

    for request in requests {
      try Task.checkCancellation()
      let rawFingerprint = try FileFingerprint.capture(request.rawFile.url, includeDigest: true)
      let resolvedSidecar = try resolveSidecar(for: request.rawFile)
      let sidecarExists = fileManager.fileExists(atPath: resolvedSidecar.url.path)
      let sidecarFingerprint =
        sidecarExists
        ? try FileFingerprint.capture(resolvedSidecar.url, includeDigest: true)
        : nil
      let sidecarMetadata: SidecarMetadata?
      let sidecarReadFailure: String?
      if sidecarExists {
        do {
          sidecarMetadata = try await metadataTool.readSidecarMetadata(at: resolvedSidecar)
          sidecarReadFailure = nil
        } catch {
          sidecarMetadata = nil
          sidecarReadFailure = String(describing: error)
        }
      } else {
        sidecarMetadata = nil
        sidecarReadFailure = nil
      }
      let rawGPS = metadataByURL[request.rawFile.url]?.gps
      let sidecarGPS = sidecarMetadata?.gps
      let existingGPS = sidecarGPS ?? rawGPS
      let proof = provenanceProof(
        rawFile: request.rawFile,
        sidecar: resolvedSidecar,
        rawFingerprint: rawFingerprint,
        sidecarFingerprint: sidecarFingerprint,
        existingGPS: sidecarGPS,
        manifests: priorManifests
      )
      let existingOrigin: ExistingGPSOrigin? = {
        if sidecarGPS != nil {
          return proof == nil ? .externalSidecar : .rawGeoSyncTransaction
        }
        return rawGPS == nil ? nil : .embeddedMedia
      }()
      let disposition: SidecarWriteDisposition
      if let sidecarReadFailure {
        disposition = .conflict("无法安全读取现有 XMP：\(sidecarReadFailure)")
      } else {
        disposition = decideDisposition(
          desired: request.gps,
          rawGPS: rawGPS,
          sidecarGPS: sidecarGPS,
          rawGPSIsPartial: metadataByURL[request.rawFile.url]?.gpsIsPartial == true,
          sidecarGPSIsPartial: sidecarMetadata?.gpsIsPartial == true,
          sidecarExists: sidecarExists,
          policy: request.existingGPSPolicy,
          desiredProvenance: request.matchProvenance,
          existingProvenance: proof?.provenance,
          existingOrigin: existingOrigin
        )
      }

      items.append(
        SidecarWritePlanItem(
          rawFile: request.rawFile,
          sidecar: resolvedSidecar,
          desiredGPS: request.gps,
          disposition: disposition,
          rawPrecondition: rawFingerprint,
          sidecarPrecondition: sidecarFingerprint,
          originalNonGPSSemanticDigest: sidecarMetadata?.nonGPSSemanticDigest,
          matchProvenance: request.matchProvenance,
          existingGPS: existingGPS,
          existingGPSOrigin: existingOrigin,
          existingMatchProvenance: proof?.provenance,
          provenanceTransactionID: proof?.transactionID
        ))
    }
    return SidecarWritePlan(items: items)
  }

  public func apply(_ plan: SidecarWritePlan) async throws -> TransactionApplyReport {
    let transactionDirectory = backupRoot.appendingPathComponent(
      plan.id.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
    var manifest = XMPTransactionManifest(plan: plan)
    try save(&manifest, in: transactionDirectory)

    var wasCancelled = false
    for index in manifest.records.indices
    where manifest.records[index].planItem.disposition.isWritable {
      if Task.isCancelled {
        wasCancelled = true
        break
      }
      manifest.records[index].status = .applying
      try save(&manifest, in: transactionDirectory)
      do {
        try await applyRecord(
          at: index, manifest: &manifest, transactionDirectory: transactionDirectory)
        manifest.records[index].status = .applied
        try save(&manifest, in: transactionDirectory)
      } catch {
        manifest.records[index].status = .failed
        manifest.records[index].failureDescription = String(describing: error)
        try save(&manifest, in: transactionDirectory)
        if error is CancellationError || error as? MetadataInfrastructureError == .cancelled {
          wasCancelled = true
          break
        }
      }
    }
    let failedCount = manifest.records.count { $0.status == .failed }
    if wasCancelled {
      manifest.status = .cancelled
    } else if failedCount > 0 {
      manifest.status = .completedWithFailures
    } else {
      manifest.status = .completed
    }
    try save(&manifest, in: transactionDirectory)
    return TransactionApplyReport(
      transactionID: manifest.id,
      appliedCount: manifest.records.count { $0.status == .applied },
      failedCount: failedCount,
      skippedCount: manifest.records.count { $0.status == .skipped },
      wasCancelled: wasCancelled
    )
  }

  public func undo(transactionID: UUID) throws {
    let transactionDirectory = backupRoot.appendingPathComponent(
      transactionID.uuidString, isDirectory: true)
    var manifest = try loadManifest(from: transactionDirectory)
    guard [.completed, .completedWithFailures, .cancelled].contains(manifest.status) else {
      throw MetadataInfrastructureError.transactionCannotBeUndone(transactionID)
    }

    let appliedIndices = manifest.records.indices.filter { manifest.records[$0].status == .applied }
    for index in appliedIndices {
      let record = manifest.records[index]
      guard let expected = record.postWriteFingerprint,
        fileManager.fileExists(atPath: record.planItem.sidecar.url.path),
        try FileFingerprint.capture(record.planItem.sidecar.url, includeDigest: true) == expected
      else {
        throw MetadataInfrastructureError.transactionCannotBeUndone(transactionID)
      }
      if let relative = record.backupRelativePath {
        let backup = transactionDirectory.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: backup.path) else {
          throw MetadataInfrastructureError.backupMissing(backup)
        }
      }
    }

    manifest.status = .undoing
    try save(&manifest, in: transactionDirectory)
    do {
      for index in appliedIndices.reversed() {
        try restoreRecord(manifest.records[index], transactionDirectory: transactionDirectory)
        manifest.records[index].status = .undone
        try save(&manifest, in: transactionDirectory)
      }
      manifest.status = .undone
      try save(&manifest, in: transactionDirectory)
    } catch {
      manifest.status = .undoFailed
      try? save(&manifest, in: transactionDirectory)
      throw error
    }
  }

  public func manifest(transactionID: UUID) throws -> XMPTransactionManifest {
    let directory = backupRoot.appendingPathComponent(transactionID.uuidString, isDirectory: true)
    return try loadManifest(from: directory)
  }

  /// 供应用启动时发现已完成、失败、取消或中断在 applying 状态的事务。
  public func transactionIDs() throws -> [UUID] {
    guard fileManager.fileExists(atPath: backupRoot.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: backupRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    .compactMap { UUID(uuidString: $0.lastPathComponent) }
    .sorted { $0.uuidString < $1.uuidString }
  }

  /// 删除超出最近批次数量或超过期限的终态事务；中断和撤销失败事务始终保留。
  public func cleanupBackups(
    maximumCount: Int = 10,
    maximumAge: TimeInterval = 30 * 24 * 60 * 60,
    now: Date = Date()
  ) throws -> BackupCleanupReport {
    guard maximumCount >= 0, maximumAge >= 0 else {
      throw MetadataInfrastructureError.invalidRetentionPolicy
    }
    let ids = try transactionIDs()
    let loaded = ids.compactMap { id -> XMPTransactionManifest? in
      try? loadManifest(from: backupRoot.appendingPathComponent(id.uuidString, isDirectory: true))
    }
    let removableStatuses: Set<TransactionStatus> = [
      .completed, .completedWithFailures, .cancelled, .undone,
    ]
    let terminal =
      loaded
      .filter { removableStatuses.contains($0.status) }
      .sorted { $0.createdAt > $1.createdAt }
    let terminalIDs = Set(terminal.map(\.id))
    var removed: [UUID] = []
    var retained = ids.filter { !terminalIDs.contains($0) }

    for (index, manifest) in terminal.enumerated() {
      let isWithinCount = index < maximumCount
      let isWithinAge = now.timeIntervalSince(manifest.createdAt) <= maximumAge
      if isWithinCount && isWithinAge {
        retained.append(manifest.id)
      } else {
        let directory = backupRoot.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        try fileManager.removeItem(at: directory)
        removed.append(manifest.id)
      }
    }
    return BackupCleanupReport(
      removedTransactionIDs: removed.sorted { $0.uuidString < $1.uuidString },
      retainedTransactionIDs: retained.sorted { $0.uuidString < $1.uuidString }
    )
  }

  private func decideDisposition(
    desired: GPSMetadata,
    rawGPS: GPSMetadata?,
    sidecarGPS: GPSMetadata?,
    rawGPSIsPartial: Bool,
    sidecarGPSIsPartial: Bool,
    sidecarExists: Bool,
    policy: ExistingGPSPolicy,
    desiredProvenance: MatchProvenance?,
    existingProvenance: MatchProvenance?,
    existingOrigin: ExistingGPSOrigin?
  ) -> SidecarWriteDisposition {
    if rawGPSIsPartial || sidecarGPSIsPartial {
      return .conflict("文件中存在不完整的 GPS 元数据")
    }
    if let rawGPS, let sidecarGPS, !rawGPS.isEquivalent(to: sidecarGPS) {
      return .conflict("RAW 与 XMP 中已有的 GPS 不一致")
    }
    if let existing = sidecarGPS ?? rawGPS {
      if existing.isEquivalent(to: desired) { return .alreadyApplied }
      switch policy {
      case .skip:
        return .conflict("文件中已有不同 GPS")
      case .replace:
        break
      case .replaceIfStrongerProvenance:
        guard existingOrigin == .rawGeoSyncTransaction,
          let desiredProvenance,
          let existingProvenance,
          desiredProvenance.isProvablyStronger(than: existingProvenance)
        else {
          return .conflict("已有 GPS 无法证明来自较弱的 RawGeoSync 匹配；未知外部 XMP 受保护")
        }
      }
    }
    return sidecarExists ? .update : .create
  }

  private func provenanceManifests() -> [XMPTransactionManifest] {
    guard let ids = try? transactionIDs() else { return [] }
    let terminal: Set<TransactionStatus> = [.completed, .completedWithFailures, .cancelled]
    return ids.compactMap { id in
      guard let manifest = try? self.manifest(transactionID: id),
        terminal.contains(manifest.status)
      else { return nil }
      return manifest
    }
    .sorted { $0.updatedAt > $1.updatedAt }
  }

  private func provenanceProof(
    rawFile: ReadOnlyRawFile,
    sidecar: SidecarURL,
    rawFingerprint: FileFingerprint,
    sidecarFingerprint: FileFingerprint?,
    existingGPS: GPSMetadata?,
    manifests: [XMPTransactionManifest]
  ) -> ProvenanceProof? {
    guard let rawDigest = rawFingerprint.sha256,
      let sidecarDigest = sidecarFingerprint?.sha256,
      let existingGPS
    else { return nil }
    for manifest in manifests {
      for record in manifest.records where record.status == .applied {
        let item = record.planItem
        guard item.rawFile.url == rawFile.url,
          item.sidecar.url == sidecar.url,
          item.rawPrecondition.sha256 == rawDigest,
          record.postWriteFingerprint?.sha256 == sidecarDigest,
          item.desiredGPS.isEquivalent(to: existingGPS),
          let provenance = item.matchProvenance
        else { continue }
        return ProvenanceProof(transactionID: manifest.id, provenance: provenance)
      }
    }
    return nil
  }

  private func resolveSidecar(for rawFile: ReadOnlyRawFile) throws -> SidecarURL {
    try SidecarURL.existing(for: rawFile, fileManager: fileManager) ?? SidecarURL(for: rawFile)
  }

  private func applyRecord(
    at index: Int,
    manifest: inout XMPTransactionManifest,
    transactionDirectory: URL
  ) async throws {
    let item = manifest.records[index].planItem
    try verifyPreconditions(item)

    let target = item.sidecar.url
    let temp = target.deletingLastPathComponent()
      .appendingPathComponent(".RawGeoSync-\(UUID().uuidString)-\(target.lastPathComponent)")
    defer { try? fileManager.removeItem(at: temp) }

    if fileManager.fileExists(atPath: target.path) {
      let backupName = String(format: "%04d-original.xmp", index + 1)
      let backup = transactionDirectory.appendingPathComponent(backupName)
      try fileManager.copyItem(at: target, to: backup)
      manifest.records[index].backupRelativePath = backupName
      try fileManager.copyItem(at: target, to: temp)
    } else {
      try Self.minimalXMP.write(to: temp, options: .withoutOverwriting)
    }
    try save(&manifest, in: transactionDirectory)
    let temporarySidecar = try SidecarURL(validatedURL: temp)
    try await metadataTool.writeGPS(item.desiredGPS, to: temporarySidecar)
    let temporaryMetadata = try await metadataTool.readSidecarMetadata(at: temporarySidecar)
    guard let writtenGPS = temporaryMetadata.gps,
      writtenGPS.isEquivalent(to: item.desiredGPS)
    else {
      throw MetadataInfrastructureError.verificationFailed(target)
    }
    if let originalDigest = item.originalNonGPSSemanticDigest,
      temporaryMetadata.nonGPSSemanticDigest != originalDigest
    {
      throw MetadataInfrastructureError.semanticMetadataChanged(target)
    }

    var targetWasMutated = false
    do {
      if fileManager.fileExists(atPath: target.path) {
        _ = try fileManager.replaceItemAt(target, withItemAt: temp)
      } else {
        try fileManager.moveItem(at: temp, to: target)
      }
      targetWasMutated = true
      manifest.records[index].postWriteFingerprint = try FileFingerprint.capture(
        target, includeDigest: true)
      try save(&manifest, in: transactionDirectory)
      let finalMetadata = try await metadataTool.readSidecarMetadata(at: item.sidecar)
      guard let finalGPS = finalMetadata.gps,
        finalGPS.isEquivalent(to: item.desiredGPS),
        item.originalNonGPSSemanticDigest == nil
          || finalMetadata.nonGPSSemanticDigest == item.originalNonGPSSemanticDigest
      else {
        throw MetadataInfrastructureError.verificationFailed(target)
      }
    } catch {
      if targetWasMutated {
        do {
          try restoreRecord(manifest.records[index], transactionDirectory: transactionDirectory)
          manifest.records[index].postWriteFingerprint = nil
          try save(&manifest, in: transactionDirectory)
        } catch let restorationError {
          throw MetadataInfrastructureError.sidecarConflict(
            target,
            "单文件写入失败且恢复失败：\(restorationError)"
          )
        }
      }
      throw error
    }
  }

  private func verifyPreconditions(_ item: SidecarWritePlanItem) throws {
    guard try FileFingerprint.capture(item.rawFile.url, includeDigest: true) == item.rawPrecondition
    else {
      throw MetadataInfrastructureError.preconditionChanged(item.rawFile.url)
    }
    let exists = fileManager.fileExists(atPath: item.sidecar.url.path)
    switch item.sidecarPrecondition {
    case nil where exists:
      throw MetadataInfrastructureError.preconditionChanged(item.sidecar.url)
    case let expected? where !exists:
      _ = expected
      throw MetadataInfrastructureError.preconditionChanged(item.sidecar.url)
    case let expected?:
      guard try FileFingerprint.capture(item.sidecar.url, includeDigest: true) == expected else {
        throw MetadataInfrastructureError.preconditionChanged(item.sidecar.url)
      }
    case nil:
      break
    }
  }

  private func restoreRecord(_ record: TransactionFileRecord, transactionDirectory: URL) throws {
    let target = record.planItem.sidecar.url
    if let relative = record.backupRelativePath {
      let backup = transactionDirectory.appendingPathComponent(relative)
      guard fileManager.fileExists(atPath: backup.path) else {
        throw MetadataInfrastructureError.backupMissing(backup)
      }
      let temp = target.deletingLastPathComponent()
        .appendingPathComponent(".RawGeoSync-restore-\(UUID().uuidString).xmp")
      defer { try? fileManager.removeItem(at: temp) }
      try fileManager.copyItem(at: backup, to: temp)
      _ = try fileManager.replaceItemAt(target, withItemAt: temp)
    } else if fileManager.fileExists(atPath: target.path) {
      try fileManager.removeItem(at: target)
    }
  }

  private func save(_ manifest: inout XMPTransactionManifest, in directory: URL) throws {
    manifest.updatedAt = Date()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
      to: directory.appendingPathComponent("manifest.json"),
      options: .atomic
    )
  }

  private func loadManifest(from directory: URL) throws -> XMPTransactionManifest {
    let url = directory.appendingPathComponent("manifest.json")
    guard fileManager.fileExists(atPath: url.path) else {
      let id = UUID(uuidString: directory.lastPathComponent) ?? UUID()
      throw MetadataInfrastructureError.transactionNotFound(id)
    }
    let decoder = JSONDecoder()
    return try decoder.decode(XMPTransactionManifest.self, from: Data(contentsOf: url))
  }

  private static let minimalXMP = Data(
    """
    <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""/>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """.utf8
  )
}
