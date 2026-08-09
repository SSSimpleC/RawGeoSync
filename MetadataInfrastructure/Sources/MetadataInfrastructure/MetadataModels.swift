import Foundation

public enum MetadataInfrastructureError: Error, LocalizedError, Equatable, Sendable {
  case notAFile(URL)
  case unsupportedRawExtension(String)
  case symbolicLinkNotAllowed(URL)
  case unsafeFileName(URL)
  case executableFailed(status: Int32, stderr: String)
  case malformedExifToolOutput(String)
  case missingMetadata(URL)
  case invalidCoordinate(latitude: Double, longitude: Double)
  case timedOut
  case cancelled
  case preconditionChanged(URL)
  case sidecarConflict(URL, String)
  case semanticMetadataChanged(URL)
  case verificationFailed(URL)
  case transactionNotFound(UUID)
  case transactionCannotBeUndone(UUID)
  case backupMissing(URL)
  case invalidRetentionPolicy

  public var errorDescription: String? {
    switch self {
    case .notAFile(let url):
      "不是普通文件：\(url.path)"
    case .unsupportedRawExtension(let ext):
      "暂不支持照片扩展名：\(ext)"
    case .symbolicLinkNotAllowed(let url):
      "为避免写入到意外位置，不允许符号链接：\(url.path)"
    case .unsafeFileName(let url):
      "文件名包含换行或控制字符：\(url.lastPathComponent)"
    case .executableFailed(let status, let stderr):
      "ExifTool 执行失败（\(status)）：\(stderr)"
    case .malformedExifToolOutput(let detail):
      "ExifTool 输出无法解析：\(detail)"
    case .missingMetadata(let url):
      "未读取到文件元数据：\(url.path)"
    case .invalidCoordinate(let latitude, let longitude):
      "坐标超出范围：\(latitude), \(longitude)"
    case .timedOut:
      "外部工具执行超时"
    case .cancelled:
      "操作已取消"
    case .preconditionChanged(let url):
      "预览后文件发生变化，请重新分析：\(url.path)"
    case .sidecarConflict(let url, let detail):
      "XMP 冲突（\(url.path)）：\(detail)"
    case .semanticMetadataChanged(let url):
      "写入 GPS 时检测到其他 XMP 元数据变化：\(url.path)"
    case .verificationFailed(let url):
      "GPS 写入后复读验证失败：\(url.path)"
    case .transactionNotFound(let id):
      "找不到事务：\(id.uuidString)"
    case .transactionCannotBeUndone(let id):
      "事务当前不能安全撤销：\(id.uuidString)"
    case .backupMissing(let url):
      "XMP 备份不存在：\(url.path)"
    case .invalidRetentionPolicy:
      "备份保留数量和期限必须大于或等于零"
    }
  }
}

public enum ReadOnlyMediaKind: String, Codable, Hashable, Sendable {
  case proprietaryRaw
  case dng
  case jpeg
  case tiff
}

/// 所有可扫描照片的只读句柄。它不能直接成为 sidecar 写入目标。
public struct ReadOnlyMediaFile: Hashable, Codable, Sendable {
  public static let supportedExtensions: Set<String> = [
    "nef", "nrw", "arw", "cr2", "cr3", "raf", "orf", "rw2", "dng",
    "jpg", "jpeg", "tif", "tiff",
  ]

  public let url: URL
  public let kind: ReadOnlyMediaKind

  public init(url: URL) throws {
    let normalized = try Self.validate(url)
    let ext = normalized.pathExtension.lowercased()
    guard Self.supportedExtensions.contains(ext) else {
      throw MetadataInfrastructureError.unsupportedRawExtension(ext)
    }
    self.url = normalized
    switch ext {
    case "dng": self.kind = .dng
    case "jpg", "jpeg": self.kind = .jpeg
    case "tif", "tiff": self.kind = .tiff
    default: self.kind = .proprietaryRaw
    }
  }

  fileprivate init(validatedURL: URL, kind: ReadOnlyMediaKind) {
    self.url = validatedURL
    self.kind = kind
  }

  fileprivate static func validate(_ url: URL) throws -> URL {
    let normalized = url.standardizedFileURL
    guard normalized.isFileURL else {
      throw MetadataInfrastructureError.notAFile(normalized)
    }
    try validateSafeName(normalized)
    let values = try normalized.resourceValues(forKeys: [
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true else {
      throw MetadataInfrastructureError.notAFile(normalized)
    }
    guard values.isSymbolicLink != true else {
      throw MetadataInfrastructureError.symbolicLinkNotAllowed(normalized)
    }
    return normalized
  }

  fileprivate static func validateSafeName(_ url: URL) throws {
    if url.path.unicodeScalars.contains(where: { scalar in
      CharacterSet.controlCharacters.contains(scalar)
    }) {
      throw MetadataInfrastructureError.unsafeFileName(url)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case url, kind
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decoded = try Self(url: container.decode(URL.self, forKey: .url))
    if let encodedKind = try container.decodeIfPresent(ReadOnlyMediaKind.self, forKey: .kind),
      encodedKind != decoded.kind
    {
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "媒体类型与文件扩展名不一致"
      )
    }
    self = decoded
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(url, forKey: .url)
    try container.encode(kind, forKey: .kind)
  }
}

/// 允许生成相邻 XMP sidecar 的专有 RAW。DNG/JPEG/TIFF 无法构造此类型。
public struct ReadOnlyRawFile: Hashable, Codable, Sendable {
  public static let supportedExtensions: Set<String> = [
    "nef", "nrw", "arw", "cr2", "cr3", "raf", "orf", "rw2",
  ]

  public let url: URL

  public init(url: URL) throws {
    let media = try ReadOnlyMediaFile(url: url)
    guard media.kind == .proprietaryRaw else {
      throw MetadataInfrastructureError.unsupportedRawExtension(
        media.url.pathExtension.lowercased())
    }
    self.url = media.url
  }

  public init(mediaFile: ReadOnlyMediaFile) throws {
    guard mediaFile.kind == .proprietaryRaw else {
      throw MetadataInfrastructureError.unsupportedRawExtension(
        mediaFile.url.pathExtension.lowercased()
      )
    }
    self.url = mediaFile.url
  }

  public var mediaFile: ReadOnlyMediaFile {
    ReadOnlyMediaFile(validatedURL: url, kind: .proprietaryRaw)
  }

  private enum CodingKeys: String, CodingKey {
    case url
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(url: container.decode(URL.self, forKey: .url))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(url, forKey: .url)
  }
}

/// 只能指向相邻 XMP sidecar 的写入目标。
public struct SidecarURL: Hashable, Codable, Sendable {
  public let url: URL

  public init(for rawFile: ReadOnlyRawFile) throws {
    let url = rawFile.url
      .deletingPathExtension()
      .appendingPathExtension("xmp")
      .standardizedFileURL
    try ReadOnlyMediaFile.validateSafeName(url)
    self.url = url
  }

  /// 从已经枚举到的相邻 XMP 构造目标。批量扫描可先按目录建立一次索引，
  /// 避免为目录中的每张 RAW 重复枚举全部文件。
  public init(existingURL url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw MetadataInfrastructureError.notAFile(url)
    }
    try self.init(validatedURL: url)
  }

  public static func existing(
    for rawFile: ReadOnlyRawFile,
    fileManager: FileManager = .default
  ) throws -> SidecarURL? {
    let expected = try SidecarURL(for: rawFile)
    let directory = rawFile.url.deletingLastPathComponent()
    let baseName = rawFile.url.deletingPathExtension().lastPathComponent
    let entries = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { candidate in
      guard candidate.deletingPathExtension().lastPathComponent == baseName,
        candidate.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame,
        let values = try? candidate.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey,
        ])
      else { return false }
      return values.isRegularFile == true && values.isSymbolicLink != true
    }
    if entries.count > 1 {
      throw MetadataInfrastructureError.sidecarConflict(
        expected.url,
        "同时存在多个大小写不同的 XMP"
      )
    }
    return try entries.first.map(SidecarURL.init(validatedURL:))
  }

  init(validatedURL url: URL) throws {
    let normalized = url.standardizedFileURL
    guard normalized.isFileURL, normalized.pathExtension.lowercased() == "xmp" else {
      throw MetadataInfrastructureError.notAFile(normalized)
    }
    try ReadOnlyMediaFile.validateSafeName(normalized)
    self.url = normalized
  }
}

public struct GPSMetadata: Hashable, Codable, Sendable {
  public let latitude: Double
  public let longitude: Double
  public let altitude: Double?

  public init(latitude: Double, longitude: Double, altitude: Double? = nil) throws {
    guard latitude.isFinite,
      longitude.isFinite,
      (-90...90).contains(latitude),
      (-180...180).contains(longitude),
      altitude?.isFinite != false
    else {
      throw MetadataInfrastructureError.invalidCoordinate(
        latitude: latitude,
        longitude: longitude
      )
    }
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
  }

  public func isEquivalent(
    to other: GPSMetadata, horizontalTolerance: Double = 0.000_001, altitudeTolerance: Double = 0.1
  ) -> Bool {
    guard abs(latitude - other.latitude) <= horizontalTolerance,
      abs(longitude - other.longitude) <= horizontalTolerance
    else {
      return false
    }
    switch (altitude, other.altitude) {
    case (nil, _), (_, nil):
      return true
    case (let lhs?, let rhs?):
      return abs(lhs - rhs) <= altitudeTolerance
    }
  }
}

public struct MediaMetadata: Hashable, Codable, Sendable {
  public let mediaFile: ReadOnlyMediaFile
  public let dateTimeOriginal: String?
  public let subsecondTimeOriginal: String?
  public let offsetTimeOriginal: String?
  public let gps: GPSMetadata?
  public let gpsIsPartial: Bool
  public let make: String?
  public let model: String?
  public let serialNumber: String?
  public let internalSerialNumber: String?
  public let shutterCount: Int?
  public let fileSize: Int64?
  public let gpsDateTime: String?
  public let gpsHorizontalPositioningError: Double?
  public let documentID: String?
  public let originalDocumentID: String?
  /// 标量按原值保存；结构化 DerivedFrom 保存为稳定排序的 JSON。
  public let derivedFrom: String?
  public let software: String?
  public let xmpToolkit: String?

  public init(
    mediaFile: ReadOnlyMediaFile,
    dateTimeOriginal: String? = nil,
    subsecondTimeOriginal: String? = nil,
    offsetTimeOriginal: String? = nil,
    gps: GPSMetadata? = nil,
    gpsIsPartial: Bool = false,
    make: String? = nil,
    model: String? = nil,
    serialNumber: String? = nil,
    internalSerialNumber: String? = nil,
    shutterCount: Int? = nil,
    fileSize: Int64? = nil,
    gpsDateTime: String? = nil,
    gpsHorizontalPositioningError: Double? = nil,
    documentID: String? = nil,
    originalDocumentID: String? = nil,
    derivedFrom: String? = nil,
    software: String? = nil,
    xmpToolkit: String? = nil
  ) {
    self.mediaFile = mediaFile
    self.dateTimeOriginal = dateTimeOriginal
    self.subsecondTimeOriginal = subsecondTimeOriginal
    self.offsetTimeOriginal = offsetTimeOriginal
    self.gps = gps
    self.gpsIsPartial = gpsIsPartial
    self.make = make
    self.model = model
    self.serialNumber = serialNumber
    self.internalSerialNumber = internalSerialNumber
    self.shutterCount = shutterCount
    self.fileSize = fileSize
    self.gpsDateTime = gpsDateTime
    self.gpsHorizontalPositioningError = gpsHorizontalPositioningError
    self.documentID = documentID
    self.originalDocumentID = originalDocumentID
    self.derivedFrom = derivedFrom
    self.software = software
    self.xmpToolkit = xmpToolkit
  }

  public init(rawMetadata: RawPhotoMetadata) {
    self.init(
      mediaFile: rawMetadata.rawFile.mediaFile,
      dateTimeOriginal: rawMetadata.dateTimeOriginal,
      subsecondTimeOriginal: rawMetadata.subsecondTimeOriginal,
      offsetTimeOriginal: rawMetadata.offsetTimeOriginal,
      gps: rawMetadata.gps,
      gpsIsPartial: rawMetadata.gpsIsPartial,
      make: rawMetadata.make,
      model: rawMetadata.model,
      serialNumber: rawMetadata.serialNumber,
      internalSerialNumber: rawMetadata.internalSerialNumber,
      shutterCount: rawMetadata.shutterCount,
      fileSize: rawMetadata.fileSize,
      gpsDateTime: rawMetadata.gpsDateTime,
      gpsHorizontalPositioningError: rawMetadata.gpsHorizontalPositioningError,
      documentID: rawMetadata.documentID,
      originalDocumentID: rawMetadata.originalDocumentID,
      derivedFrom: rawMetadata.derivedFrom,
      software: rawMetadata.software,
      xmpToolkit: rawMetadata.xmpToolkit
    )
  }
}

/// v1 专有 RAW 调用面的兼容模型；新扫描流程应使用 MediaMetadata。
public struct RawPhotoMetadata: Hashable, Codable, Sendable {
  public let rawFile: ReadOnlyRawFile
  public let dateTimeOriginal: String?
  public let subsecondTimeOriginal: String?
  public let offsetTimeOriginal: String?
  public let gps: GPSMetadata?
  public let gpsIsPartial: Bool
  public let make: String?
  public let model: String?
  public let serialNumber: String?
  public let internalSerialNumber: String?
  public let shutterCount: Int?
  public let fileSize: Int64?
  public let gpsDateTime: String?
  public let gpsHorizontalPositioningError: Double?
  public let documentID: String?
  public let originalDocumentID: String?
  public let derivedFrom: String?
  public let software: String?
  public let xmpToolkit: String?

  public init(
    rawFile: ReadOnlyRawFile,
    dateTimeOriginal: String?,
    subsecondTimeOriginal: String?,
    offsetTimeOriginal: String?,
    gps: GPSMetadata?,
    gpsIsPartial: Bool = false,
    make: String? = nil,
    model: String? = nil,
    serialNumber: String? = nil,
    internalSerialNumber: String? = nil,
    shutterCount: Int? = nil,
    fileSize: Int64? = nil,
    gpsDateTime: String? = nil,
    gpsHorizontalPositioningError: Double? = nil,
    documentID: String? = nil,
    originalDocumentID: String? = nil,
    derivedFrom: String? = nil,
    software: String? = nil,
    xmpToolkit: String? = nil
  ) {
    self.rawFile = rawFile
    self.dateTimeOriginal = dateTimeOriginal
    self.subsecondTimeOriginal = subsecondTimeOriginal
    self.offsetTimeOriginal = offsetTimeOriginal
    self.gps = gps
    self.gpsIsPartial = gpsIsPartial
    self.make = make
    self.model = model
    self.serialNumber = serialNumber
    self.internalSerialNumber = internalSerialNumber
    self.shutterCount = shutterCount
    self.fileSize = fileSize
    self.gpsDateTime = gpsDateTime
    self.gpsHorizontalPositioningError = gpsHorizontalPositioningError
    self.documentID = documentID
    self.originalDocumentID = originalDocumentID
    self.derivedFrom = derivedFrom
    self.software = software
    self.xmpToolkit = xmpToolkit
  }

  public init(mediaMetadata: MediaMetadata, rawFile: ReadOnlyRawFile) {
    self.init(
      rawFile: rawFile,
      dateTimeOriginal: mediaMetadata.dateTimeOriginal,
      subsecondTimeOriginal: mediaMetadata.subsecondTimeOriginal,
      offsetTimeOriginal: mediaMetadata.offsetTimeOriginal,
      gps: mediaMetadata.gps,
      gpsIsPartial: mediaMetadata.gpsIsPartial,
      make: mediaMetadata.make,
      model: mediaMetadata.model,
      serialNumber: mediaMetadata.serialNumber,
      internalSerialNumber: mediaMetadata.internalSerialNumber,
      shutterCount: mediaMetadata.shutterCount,
      fileSize: mediaMetadata.fileSize,
      gpsDateTime: mediaMetadata.gpsDateTime,
      gpsHorizontalPositioningError: mediaMetadata.gpsHorizontalPositioningError,
      documentID: mediaMetadata.documentID,
      originalDocumentID: mediaMetadata.originalDocumentID,
      derivedFrom: mediaMetadata.derivedFrom,
      software: mediaMetadata.software,
      xmpToolkit: mediaMetadata.xmpToolkit
    )
  }
}

public struct SidecarMetadata: Hashable, Codable, Sendable {
  public let gps: GPSMetadata?
  public let gpsIsPartial: Bool
  /// 除 GPS 和 ExifTool 自身标记外，其余 XMP 的规范化 SHA-256。
  public let nonGPSSemanticDigest: String
  public let documentID: String?
  public let originalDocumentID: String?
  public let derivedFrom: String?
  public let software: String?
  public let xmpToolkit: String?

  public init(
    gps: GPSMetadata?,
    gpsIsPartial: Bool = false,
    nonGPSSemanticDigest: String,
    documentID: String? = nil,
    originalDocumentID: String? = nil,
    derivedFrom: String? = nil,
    software: String? = nil,
    xmpToolkit: String? = nil
  ) {
    self.gps = gps
    self.gpsIsPartial = gpsIsPartial
    self.nonGPSSemanticDigest = nonGPSSemanticDigest
    self.documentID = documentID
    self.originalDocumentID = originalDocumentID
    self.derivedFrom = derivedFrom
    self.software = software
    self.xmpToolkit = xmpToolkit
  }
}

public struct ExifToolVersion: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
  public let components: [Int]

  public init(_ string: String) throws {
    let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
    let components = parts.compactMap { Int($0) }
    guard components.count == parts.count, !components.isEmpty else {
      throw MetadataInfrastructureError.malformedExifToolOutput("无效版本号：\(string)")
    }
    self.components = components
  }

  public var description: String {
    components.map(String.init).joined(separator: ".")
  }

  public static func < (lhs: ExifToolVersion, rhs: ExifToolVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }
}

public protocol MetadataTooling: Sendable {
  func checkVersion() async throws -> ExifToolVersion
  func readMediaMetadata(_ files: [ReadOnlyMediaFile]) async throws -> [MediaMetadata]
  func readRawMetadata(_ files: [ReadOnlyRawFile]) async throws -> [RawPhotoMetadata]
  func readSidecarMetadata(at sidecar: SidecarURL) async throws -> SidecarMetadata
  func writeGPS(_ gps: GPSMetadata, to sidecar: SidecarURL) async throws
}

extension MetadataTooling {
  /// v1 工具实现的兼容适配；跨格式扫描工具应覆盖此方法。
  public func readMediaMetadata(_ files: [ReadOnlyMediaFile]) async throws -> [MediaMetadata] {
    let rawFiles = try files.map(ReadOnlyRawFile.init(mediaFile:))
    return try await readRawMetadata(rawFiles).map(MediaMetadata.init(rawMetadata:))
  }
}
