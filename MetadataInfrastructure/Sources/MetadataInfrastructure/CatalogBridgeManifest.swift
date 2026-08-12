import CryptoKit
import Darwin
import Foundation

public enum CatalogBridgeManifestError: Error, LocalizedError, Equatable, Sendable {
  case notAFile(URL)
  case unsupportedSchema(major: Int, minor: Int)
  case malformedLine(Int)
  case unexpectedLine(type: String, line: Int)
  case unsafeRelativePath(String)
  case duplicateRelativePath(String)
  case duplicateRecordID(UUID)
  case invalidValue(String)
  case recordDigestMismatch(line: Int)
  case payloadDigestMismatch
  case recordCountMismatch(expected: Int, actual: Int)
  case damagedExistingTarget(URL)

  public var errorDescription: String? {
    switch self {
    case .notAFile(let url): "不是普通文件：\(url.path)"
    case .unsupportedSchema(let major, let minor): "不支持的清单版本：\(major).\(minor)"
    case .malformedLine(let line): "清单第 \(line) 行不是有效 JSON"
    case .unexpectedLine(let type, let line): "清单第 \(line) 行类型不正确：\(type)"
    case .unsafeRelativePath(let path): "照片相对路径不安全：\(path)"
    case .duplicateRelativePath(let path): "照片相对路径重复：\(path)"
    case .duplicateRecordID(let id): "照片记录 ID 重复：\(id.uuidString)"
    case .invalidValue(let field): "清单字段无效：\(field)"
    case .recordDigestMismatch(let line): "清单第 \(line) 行记录摘要不匹配"
    case .payloadDigestMismatch: "清单整体摘要不匹配"
    case .recordCountMismatch(let expected, let actual):
      "清单记录数不匹配：声明 \(expected)，实际 \(actual)"
    case .damagedExistingTarget(let url): "已有清单损坏，已拒绝覆盖：\(url.path)"
    }
  }
}

public struct CatalogBridgeSchemaVersion: Hashable, Codable, Sendable {
  public static let current = CatalogBridgeSchemaVersion(major: 1, minor: 0)
  public let major: Int
  public let minor: Int

  public init(major: Int, minor: Int) {
    self.major = major
    self.minor = minor
  }
}

public struct CatalogBridgeManifestHeader: Hashable, Codable, Sendable {
  public let type: String
  public let format: String
  public let schemaVersion: CatalogBridgeSchemaVersion
  public let manifestID: UUID
  public let activityID: UUID
  public let revision: Int
  public let createdAtUTC: Date
  public let appVersion: String
  public let algorithmVersion: String
  public let recordCount: Int
  public let skippedCount: Int
  public let rootDisplayName: String
  public let writeAltitude: Bool
  public let existingGPSPolicy: String
  public let priorPayloadSHA256: String?

  public init(
    format: String = CatalogBridgeManifest.formatIdentifier,
    schemaVersion: CatalogBridgeSchemaVersion = .current,
    manifestID: UUID = UUID(),
    activityID: UUID = UUID(),
    revision: Int = 1,
    createdAtUTC: Date = Date(),
    appVersion: String,
    algorithmVersion: String,
    recordCount: Int,
    skippedCount: Int = 0,
    rootDisplayName: String,
    writeAltitude: Bool = false,
    existingGPSPolicy: String = "overwrite",
    priorPayloadSHA256: String? = nil
  ) {
    self.type = "header"
    self.format = format
    self.schemaVersion = schemaVersion
    self.manifestID = manifestID
    self.activityID = activityID
    self.revision = revision
    self.createdAtUTC = createdAtUTC
    self.appVersion = appVersion
    self.algorithmVersion = algorithmVersion
    self.recordCount = recordCount
    self.skippedCount = skippedCount
    self.rootDisplayName = rootDisplayName
    self.writeAltitude = writeAltitude
    self.existingGPSPolicy = existingGPSPolicy
    self.priorPayloadSHA256 = priorPayloadSHA256
  }
}

public struct CatalogBridgeFileIdentity: Hashable, Codable, Sendable {
  public let byteCount: Int64
  public let exifDateTimeOriginal: String
  public let subsecondTimeOriginal: String?
  public let offsetTimeOriginal: String?
  public let make: String?
  public let model: String?
  public let serialNumber: String?
  public let internalSerialNumber: String?
  public let shutterCount: Int?

  public init(
    byteCount: Int64,
    exifDateTimeOriginal: String,
    subsecondTimeOriginal: String? = nil,
    offsetTimeOriginal: String? = nil,
    make: String? = nil,
    model: String? = nil,
    serialNumber: String? = nil,
    internalSerialNumber: String? = nil,
    shutterCount: Int? = nil
  ) {
    self.byteCount = byteCount
    self.exifDateTimeOriginal = exifDateTimeOriginal
    self.subsecondTimeOriginal = subsecondTimeOriginal
    self.offsetTimeOriginal = offsetTimeOriginal
    self.make = make
    self.model = model
    self.serialNumber = serialNumber
    self.internalSerialNumber = internalSerialNumber
    self.shutterCount = shutterCount
  }
}

public enum CatalogBridgeVerification: String, Hashable, Codable, Sendable {
  case automatic
  case userConfirmed
  case manual
}

public struct CatalogBridgeDecision: Hashable, Codable, Sendable {
  public let confidence: String
  public let method: String
  public let granularity: String
  public let verification: CatalogBridgeVerification
  public let ruleVersion: String
  public let estimatedRadiusMeters: Double?
  public let temporalDistanceSeconds: Double?
  public let evidenceSummary: String?
  public let trackFileSHA256: String?

  public init(
    confidence: String,
    method: String,
    granularity: String,
    verification: CatalogBridgeVerification,
    ruleVersion: String,
    estimatedRadiusMeters: Double? = nil,
    temporalDistanceSeconds: Double? = nil,
    evidenceSummary: String? = nil,
    trackFileSHA256: String? = nil
  ) {
    self.confidence = confidence
    self.method = method
    self.granularity = granularity
    self.verification = verification
    self.ruleVersion = ruleVersion
    self.estimatedRadiusMeters = estimatedRadiusMeters
    self.temporalDistanceSeconds = temporalDistanceSeconds
    self.evidenceSummary = evidenceSummary
    self.trackFileSHA256 = trackFileSHA256
  }
}

public struct CatalogBridgeAssetRecord: Hashable, Codable, Sendable, Identifiable {
  public let type: String
  public let recordID: UUID
  public let relativePath: String
  public let assetKind: String
  public let fileIdentity: CatalogBridgeFileIdentity
  public let correctedCaptureTimeUTC: Date
  public let location: GPSMetadata
  public let decision: CatalogBridgeDecision
  public let recordDigestSHA256: String?

  public var id: UUID { recordID }

  public init(
    recordID: UUID = UUID(),
    relativePath: String,
    assetKind: String = "proprietaryRaw",
    fileIdentity: CatalogBridgeFileIdentity,
    correctedCaptureTimeUTC: Date,
    location: GPSMetadata,
    decision: CatalogBridgeDecision,
    recordDigestSHA256: String? = nil
  ) {
    self.type = "asset"
    self.recordID = recordID
    self.relativePath = relativePath
    self.assetKind = assetKind
    self.fileIdentity = fileIdentity
    self.correctedCaptureTimeUTC = correctedCaptureTimeUTC
    self.location = location
    self.decision = decision
    self.recordDigestSHA256 = recordDigestSHA256
  }
}

public struct CatalogBridgeManifest: Hashable, Sendable {
  public static let fileName = "RawGeoSync.locations.jsonl"
  public static let formatIdentifier = "com.sssimplec.rawgeosync.locations"

  public let header: CatalogBridgeManifestHeader
  public let assets: [CatalogBridgeAssetRecord]
  public let payloadSHA256: String

  public init(
    header: CatalogBridgeManifestHeader,
    assets: [CatalogBridgeAssetRecord],
    payloadSHA256: String
  ) {
    self.header = header
    self.assets = assets
    self.payloadSHA256 = payloadSHA256
  }
}

public enum CatalogBridgeWriteResult: Sendable {
  case written(CatalogBridgeManifest)
  case unchanged(CatalogBridgeManifest)

  public var manifest: CatalogBridgeManifest {
    switch self {
    case .written(let value), .unchanged(let value): value
    }
  }
}

public struct CatalogBridgeExportRequest: Sendable {
  public let rootDirectoryURL: URL
  public let assets: [CatalogBridgeAssetRecord]
  public let appVersion: String
  public let algorithmVersion: String
  public let skippedCount: Int
  public let writeAltitude: Bool

  public init(
    rootDirectoryURL: URL,
    assets: [CatalogBridgeAssetRecord],
    appVersion: String,
    algorithmVersion: String,
    skippedCount: Int = 0,
    writeAltitude: Bool = false
  ) {
    self.rootDirectoryURL = rootDirectoryURL
    self.assets = assets
    self.appVersion = appVersion
    self.algorithmVersion = algorithmVersion
    self.skippedCount = skippedCount
    self.writeAltitude = writeAltitude
  }
}

public enum CatalogBridgeExportDisposition: String, Codable, Equatable, Sendable {
  case created
  case replaced
  case unchanged
}

public struct CatalogBridgeExportResult: Sendable {
  public let artifactURL: URL
  public let manifest: CatalogBridgeManifest
  public let disposition: CatalogBridgeExportDisposition

  public var recordCount: Int { manifest.assets.count }
}

private struct CatalogBridgeTrailer: Codable {
  let type: String
  let recordCount: Int
  let payloadSHA256: String
}

private struct LineType: Decodable { let type: String }

public struct CatalogBridgeManifestStore {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public static func stableRecordID(
    relativePath: String,
    fileIdentity: CatalogBridgeFileIdentity
  ) throws -> UUID {
    try validateRelativePath(relativePath)
    var components: [String] = [
      relativePath,
      String(fileIdentity.byteCount),
      fileIdentity.exifDateTimeOriginal,
    ]
    components.append(fileIdentity.subsecondTimeOriginal ?? "")
    components.append(fileIdentity.offsetTimeOriginal ?? "")
    components.append(fileIdentity.make ?? "")
    components.append(fileIdentity.model ?? "")
    components.append(fileIdentity.serialNumber ?? fileIdentity.internalSerialNumber ?? "")
    components.append(fileIdentity.shutterCount.map(String.init) ?? "")
    let seed = components.joined(separator: "\u{0}")
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  public func export(_ request: CatalogBridgeExportRequest) throws -> CatalogBridgeExportResult {
    let root = request.rootDirectoryURL.standardizedFileURL
    let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw CatalogBridgeManifestError.notAFile(root)
    }
    let target = root.appendingPathComponent(CatalogBridgeManifest.fileName)
    let existed = fileManager.fileExists(atPath: target.path)
    let header = CatalogBridgeManifestHeader(
      appVersion: request.appVersion,
      algorithmVersion: request.algorithmVersion,
      recordCount: request.assets.count,
      skippedCount: max(0, request.skippedCount),
      rootDisplayName: root.lastPathComponent,
      writeAltitude: request.writeAltitude,
      existingGPSPolicy: "overwrite"
    )
    for asset in request.assets {
      try Self.validateRelativePath(asset.relativePath)
      let candidate = asset.relativePath.split(separator: "/").reduce(root) { partial, component in
        partial.appendingPathComponent(String(component))
      }
      let values = try candidate.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        Int64(values.fileSize ?? -1) == asset.fileIdentity.byteCount,
        candidate.resolvingSymlinksInPath().path.hasPrefix(
          root.resolvingSymlinksInPath().path + "/"
        )
      else {
        throw CatalogBridgeManifestError.invalidValue("asset.fileIdentity")
      }
    }
    let result = try write(header: header, assets: request.assets, to: target)
    switch result {
    case .unchanged(let manifest):
      return CatalogBridgeExportResult(
        artifactURL: target,
        manifest: manifest,
        disposition: .unchanged
      )
    case .written(let manifest):
      return CatalogBridgeExportResult(
        artifactURL: target,
        manifest: manifest,
        disposition: existed ? .replaced : .created
      )
    }
  }

  /// Existing identifiers and revision history are maintained automatically.
  /// A valid target with identical asset semantics is not rewritten.
  public func write(
    header requestedHeader: CatalogBridgeManifestHeader,
    assets requestedAssets: [CatalogBridgeAssetRecord],
    to targetURL: URL
  ) throws -> CatalogBridgeWriteResult {
    let target = targetURL.standardizedFileURL
    guard target.isFileURL else { throw CatalogBridgeManifestError.notAFile(target) }
    let existing: CatalogBridgeManifest?
    if fileManager.fileExists(atPath: target.path) {
      do { existing = try read(from: target) } catch {
        throw CatalogBridgeManifestError.damagedExistingTarget(target)
      }
    } else {
      existing = nil
    }

    let assets = try normalizedAssets(requestedAssets)
    if let existing, semanticAssets(existing.assets) == semanticAssets(assets) {
      return .unchanged(existing)
    }

    let header = CatalogBridgeManifestHeader(
      manifestID: existing?.header.manifestID ?? requestedHeader.manifestID,
      activityID: existing?.header.activityID ?? requestedHeader.activityID,
      revision: existing.map { $0.header.revision + 1 } ?? 1,
      createdAtUTC: requestedHeader.createdAtUTC,
      appVersion: requestedHeader.appVersion,
      algorithmVersion: requestedHeader.algorithmVersion,
      recordCount: assets.count,
      skippedCount: requestedHeader.skippedCount,
      rootDisplayName: requestedHeader.rootDisplayName,
      writeAltitude: requestedHeader.writeAltitude,
      existingGPSPolicy: requestedHeader.existingGPSPolicy,
      priorPayloadSHA256: existing?.payloadSHA256
    )
    let (data, manifest) = try encodedManifest(header: header, assets: assets)
    let parent = target.deletingLastPathComponent()
    let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey])
    guard parentValues.isDirectory == true else {
      throw CatalogBridgeManifestError.notAFile(parent)
    }
    let temporary = parent.appendingPathComponent(".RawGeoSync-\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporary) }
    guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
      throw CatalogBridgeManifestError.notAFile(temporary)
    }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    _ = try read(from: temporary)
    if fileManager.fileExists(atPath: target.path) {
      _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: target)
    }
    let parentDescriptor = open(parent.path, O_RDONLY)
    if parentDescriptor >= 0 {
      _ = fsync(parentDescriptor)
      _ = close(parentDescriptor)
    }
    return .written(manifest)
  }

  public func read(from url: URL) throws -> CatalogBridgeManifest {
    let normalized = url.standardizedFileURL
    let values = try normalized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw CatalogBridgeManifestError.notAFile(normalized)
    }
    let handle = try FileHandle(forReadingFrom: normalized)
    defer { try? handle.close() }
    var iterator = LineIterator(handle: handle)
    guard let first = try iterator.next() else { throw CatalogBridgeManifestError.malformedLine(1) }
    let decoder = Self.decoder()
    let header: CatalogBridgeManifestHeader
    do { header = try decoder.decode(CatalogBridgeManifestHeader.self, from: first) } catch {
      throw CatalogBridgeManifestError.malformedLine(1)
    }
    try validate(header: header)
    var payloadHasher = SHA256()
    payloadHasher.update(data: first)
    payloadHasher.update(data: Data([0x0A]))
    var assets: [CatalogBridgeAssetRecord] = []
    assets.reserveCapacity(header.recordCount)
    var paths = Set<String>()
    var recordIDs = Set<UUID>()
    var lineNumber = 1
    var trailer: CatalogBridgeTrailer?
    while let line = try iterator.next() {
      lineNumber += 1
      let type: LineType
      do { type = try decoder.decode(LineType.self, from: line) } catch {
        throw CatalogBridgeManifestError.malformedLine(lineNumber)
      }
      switch type.type {
      case "asset":
        guard trailer == nil else {
          throw CatalogBridgeManifestError.unexpectedLine(type: type.type, line: lineNumber)
        }
        let record: CatalogBridgeAssetRecord
        do { record = try decoder.decode(CatalogBridgeAssetRecord.self, from: line) } catch {
          throw CatalogBridgeManifestError.malformedLine(lineNumber)
        }
        try validate(record: record, line: lineNumber)
        guard paths.insert(record.relativePath).inserted else {
          throw CatalogBridgeManifestError.duplicateRelativePath(record.relativePath)
        }
        guard recordIDs.insert(record.recordID).inserted else {
          throw CatalogBridgeManifestError.duplicateRecordID(record.recordID)
        }
        payloadHasher.update(data: line)
        payloadHasher.update(data: Data([0x0A]))
        assets.append(record)
      case "trailer":
        guard trailer == nil else {
          throw CatalogBridgeManifestError.unexpectedLine(type: type.type, line: lineNumber)
        }
        do { trailer = try decoder.decode(CatalogBridgeTrailer.self, from: line) } catch {
          throw CatalogBridgeManifestError.malformedLine(lineNumber)
        }
      default:
        throw CatalogBridgeManifestError.unexpectedLine(type: type.type, line: lineNumber)
      }
    }
    guard let trailer else { throw CatalogBridgeManifestError.malformedLine(lineNumber + 1) }
    guard header.recordCount == assets.count else {
      throw CatalogBridgeManifestError.recordCountMismatch(
        expected: header.recordCount, actual: assets.count)
    }
    guard trailer.recordCount == assets.count else {
      throw CatalogBridgeManifestError.recordCountMismatch(
        expected: trailer.recordCount, actual: assets.count)
    }
    let digest = Self.hex(payloadHasher.finalize())
    guard Self.isDigest(trailer.payloadSHA256), digest == trailer.payloadSHA256 else {
      throw CatalogBridgeManifestError.payloadDigestMismatch
    }
    return CatalogBridgeManifest(header: header, assets: assets, payloadSHA256: digest)
  }

  private func encodedManifest(
    header: CatalogBridgeManifestHeader,
    assets: [CatalogBridgeAssetRecord]
  ) throws -> (Data, CatalogBridgeManifest) {
    let encoder = Self.encoder()
    var payload = Data()
    func appendLine(_ data: Data) {
      payload.append(data)
      payload.append(0x0A)
    }
    appendLine(try encoder.encode(header))
    var encodedAssets: [CatalogBridgeAssetRecord] = []
    encodedAssets.reserveCapacity(assets.count)
    for asset in assets {
      let record = try withDigest(asset)
      appendLine(try encoder.encode(record))
      encodedAssets.append(record)
    }
    let digest = Self.hex(SHA256.hash(data: payload))
    var output = payload
    append(
      to: &output,
      line: try encoder.encode(
        CatalogBridgeTrailer(
          type: "trailer", recordCount: encodedAssets.count, payloadSHA256: digest)
      ))
    return (
      output,
      CatalogBridgeManifest(header: header, assets: encodedAssets, payloadSHA256: digest)
    )
  }

  private func normalizedAssets(_ assets: [CatalogBridgeAssetRecord]) throws
    -> [CatalogBridgeAssetRecord]
  {
    var paths = Set<String>()
    var recordIDs = Set<UUID>()
    var result: [CatalogBridgeAssetRecord] = []
    result.reserveCapacity(assets.count)
    for asset in assets {
      try validateRecordValues(asset)
      guard paths.insert(asset.relativePath).inserted else {
        throw CatalogBridgeManifestError.duplicateRelativePath(asset.relativePath)
      }
      guard recordIDs.insert(asset.recordID).inserted else {
        throw CatalogBridgeManifestError.duplicateRecordID(asset.recordID)
      }
      result.append(try withDigest(asset))
    }
    return result.sorted { $0.relativePath < $1.relativePath }
  }

  private func withDigest(_ asset: CatalogBridgeAssetRecord) throws -> CatalogBridgeAssetRecord {
    let unsigned = CatalogBridgeAssetRecord(
      recordID: asset.recordID,
      relativePath: asset.relativePath,
      assetKind: asset.assetKind,
      fileIdentity: asset.fileIdentity,
      correctedCaptureTimeUTC: asset.correctedCaptureTimeUTC,
      location: asset.location,
      decision: asset.decision,
      recordDigestSHA256: nil
    )
    let digest = Self.hex(SHA256.hash(data: try Self.encoder().encode(unsigned)))
    return CatalogBridgeAssetRecord(
      recordID: unsigned.recordID,
      relativePath: unsigned.relativePath,
      assetKind: unsigned.assetKind,
      fileIdentity: unsigned.fileIdentity,
      correctedCaptureTimeUTC: unsigned.correctedCaptureTimeUTC,
      location: unsigned.location,
      decision: unsigned.decision,
      recordDigestSHA256: digest
    )
  }

  private func validate(header: CatalogBridgeManifestHeader) throws {
    guard header.type == "header", header.format == CatalogBridgeManifest.formatIdentifier else {
      throw CatalogBridgeManifestError.invalidValue("header.format")
    }
    guard header.schemaVersion.major == 1, header.schemaVersion.minor <= 0 else {
      throw CatalogBridgeManifestError.unsupportedSchema(
        major: header.schemaVersion.major, minor: header.schemaVersion.minor)
    }
    guard header.revision >= 1, header.recordCount >= 0,
      !header.appVersion.isEmpty, !header.algorithmVersion.isEmpty,
      !header.rootDisplayName.isEmpty
    else { throw CatalogBridgeManifestError.invalidValue("header") }
    if let prior = header.priorPayloadSHA256, !Self.isDigest(prior) {
      throw CatalogBridgeManifestError.invalidValue("priorPayloadSHA256")
    }
  }

  private func validate(record: CatalogBridgeAssetRecord, line: Int) throws {
    try validateRecordValues(record)
    guard let expected = record.recordDigestSHA256, Self.isDigest(expected) else {
      throw CatalogBridgeManifestError.recordDigestMismatch(line: line)
    }
    let actual = try withDigest(record).recordDigestSHA256
    guard actual == expected else {
      throw CatalogBridgeManifestError.recordDigestMismatch(line: line)
    }
  }

  private func validateRecordValues(_ record: CatalogBridgeAssetRecord) throws {
    guard record.type == "asset" else {
      throw CatalogBridgeManifestError.invalidValue("asset.type")
    }
    try Self.validateRelativePath(record.relativePath)
    guard record.fileIdentity.byteCount > 0,
      !record.fileIdentity.exifDateTimeOriginal.isEmpty,
      !record.assetKind.isEmpty,
      record.location.latitude.isFinite, (-90...90).contains(record.location.latitude),
      record.location.longitude.isFinite, (-180...180).contains(record.location.longitude),
      record.location.altitude?.isFinite != false,
      record.decision.estimatedRadiusMeters.map({ $0.isFinite && $0 >= 0 }) != false,
      record.decision.temporalDistanceSeconds?.isFinite != false,
      !record.decision.confidence.isEmpty, !record.decision.method.isEmpty,
      !record.decision.granularity.isEmpty, !record.decision.ruleVersion.isEmpty
    else { throw CatalogBridgeManifestError.invalidValue("asset") }
    if let digest = record.decision.trackFileSHA256, !Self.isDigest(digest) {
      throw CatalogBridgeManifestError.invalidValue("trackFileSHA256")
    }
  }

  public static func validateRelativePath(_ path: String) throws {
    let normalized = path.precomposedStringWithCanonicalMapping
    guard path == normalized, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw CatalogBridgeManifestError.unsafeRelativePath(path) }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw CatalogBridgeManifestError.unsafeRelativePath(path) }
  }

  private struct SemanticAsset: Equatable {
    let relativePath: String
    let assetKind: String
    let fileIdentity: CatalogBridgeFileIdentity
    let correctedCaptureTimeUTC: Date
    let location: GPSMetadata
    let decision: CatalogBridgeDecision
  }

  private func semanticAssets(_ assets: [CatalogBridgeAssetRecord]) -> [SemanticAsset] {
    assets.sorted { $0.relativePath < $1.relativePath }.map { asset in
      SemanticAsset(
        relativePath: asset.relativePath,
        assetKind: asset.assetKind,
        fileIdentity: asset.fileIdentity,
        correctedCaptureTimeUTC: asset.correctedCaptureTimeUTC,
        location: asset.location,
        decision: asset.decision
      )
    }
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func isDigest(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private func append(to output: inout Data, line: Data) {
    output.append(line)
    output.append(0x0A)
  }
}

private struct LineIterator {
  let handle: FileHandle
  var buffer = Data()
  var reachedEOF = false

  mutating func next() throws -> Data? {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        if line.last == 0x0D { throw CatalogBridgeManifestError.malformedLine(0) }
        guard !line.isEmpty else { throw CatalogBridgeManifestError.malformedLine(0) }
        return line
      }
      if reachedEOF {
        guard buffer.isEmpty else { throw CatalogBridgeManifestError.malformedLine(0) }
        return nil
      }
      let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
      if chunk.isEmpty { reachedEOF = true } else { buffer.append(chunk) }
    }
  }
}
