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

/// RAW 文件的只读句柄。写入 API 不接受裸 URL 或此类型作为目标。
public struct ReadOnlyRawFile: Hashable, Codable, Sendable {
    public static let supportedExtensions: Set<String> = [
        "nef", "nrw", "arw", "cr2", "cr3", "raf", "orf", "rw2", "dng",
        "jpg", "jpeg", "tif", "tiff"
    ]

    public let url: URL

    public init(url: URL) throws {
        let normalized = url.standardizedFileURL
        guard normalized.isFileURL else {
            throw MetadataInfrastructureError.notAFile(normalized)
        }
        try Self.validateSafeName(normalized)

        let values = try normalized.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true else {
            throw MetadataInfrastructureError.notAFile(normalized)
        }
        guard values.isSymbolicLink != true else {
            throw MetadataInfrastructureError.symbolicLinkNotAllowed(normalized)
        }

        let ext = normalized.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw MetadataInfrastructureError.unsupportedRawExtension(ext)
        }
        self.url = normalized
    }

    static func validateSafeName(_ url: URL) throws {
        if url.path.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }) {
            throw MetadataInfrastructureError.unsafeFileName(url)
        }
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
        try ReadOnlyRawFile.validateSafeName(url)
        self.url = url
    }

    init(validatedURL url: URL) throws {
        let normalized = url.standardizedFileURL
        guard normalized.isFileURL, normalized.pathExtension.lowercased() == "xmp" else {
            throw MetadataInfrastructureError.notAFile(normalized)
        }
        try ReadOnlyRawFile.validateSafeName(normalized)
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
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude),
              altitude?.isFinite != false else {
            throw MetadataInfrastructureError.invalidCoordinate(
                latitude: latitude,
                longitude: longitude
            )
        }
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public func isEquivalent(to other: GPSMetadata, horizontalTolerance: Double = 0.000_001, altitudeTolerance: Double = 0.1) -> Bool {
        guard abs(latitude - other.latitude) <= horizontalTolerance,
              abs(longitude - other.longitude) <= horizontalTolerance else {
            return false
        }
        switch (altitude, other.altitude) {
        case (nil, _), (_, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs - rhs) <= altitudeTolerance
        }
    }
}

public struct RawPhotoMetadata: Hashable, Codable, Sendable {
    public let rawFile: ReadOnlyRawFile
    public let dateTimeOriginal: String?
    public let subsecondTimeOriginal: String?
    public let offsetTimeOriginal: String?
    public let gps: GPSMetadata?
    public let gpsIsPartial: Bool

    public init(
        rawFile: ReadOnlyRawFile,
        dateTimeOriginal: String?,
        subsecondTimeOriginal: String?,
        offsetTimeOriginal: String?,
        gps: GPSMetadata?,
        gpsIsPartial: Bool = false
    ) {
        self.rawFile = rawFile
        self.dateTimeOriginal = dateTimeOriginal
        self.subsecondTimeOriginal = subsecondTimeOriginal
        self.offsetTimeOriginal = offsetTimeOriginal
        self.gps = gps
        self.gpsIsPartial = gpsIsPartial
    }
}

public struct SidecarMetadata: Hashable, Codable, Sendable {
    public let gps: GPSMetadata?
    public let gpsIsPartial: Bool
    /// 除 GPS 和 ExifTool 自身标记外，其余 XMP 的规范化 SHA-256。
    public let nonGPSSemanticDigest: String

    public init(gps: GPSMetadata?, gpsIsPartial: Bool = false, nonGPSSemanticDigest: String) {
        self.gps = gps
        self.gpsIsPartial = gpsIsPartial
        self.nonGPSSemanticDigest = nonGPSSemanticDigest
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
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public protocol MetadataTooling: Sendable {
    func checkVersion() async throws -> ExifToolVersion
    func readRawMetadata(_ files: [ReadOnlyRawFile]) async throws -> [RawPhotoMetadata]
    func readSidecarMetadata(at sidecar: SidecarURL) async throws -> SidecarMetadata
    func writeGPS(_ gps: GPSMetadata, to sidecar: SidecarURL) async throws
}
