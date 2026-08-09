import CryptoKit
import Foundation

public struct ExifToolConfiguration: Hashable, Sendable {
  public let executableURL: URL
  public let leadingArguments: [String]
  public let timeout: Duration
  public let minimumVersion: ExifToolVersion

  public init(
    executableURL: URL,
    leadingArguments: [String] = [],
    timeout: Duration = .seconds(30),
    minimumVersion: ExifToolVersion
  ) {
    self.executableURL = executableURL
    self.leadingArguments = leadingArguments
    self.timeout = timeout
    self.minimumVersion = minimumVersion
  }

  public static func bundledPerl(scriptURL: URL) throws -> ExifToolConfiguration {
    ExifToolConfiguration(
      executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
      leadingArguments: [scriptURL.standardizedFileURL.path],
      timeout: .seconds(120),
      minimumVersion: try ExifToolVersion("13.59")
    )
  }
}

private enum JSONValue: Codable, Hashable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  var stringValue: String? {
    switch self {
    case .string(let value): value
    case .number(let value):
      value.rounded() == value ? String(Int64(value)) : String(value)
    default: nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .number(let value): value
    case .string(let value): Double(value)
    default: nil
    }
  }

  var int64Value: Int64? {
    switch self {
    case .number(let value) where value.isFinite:
      Int64(exactly: value)
    case .string(let value):
      Int64(value)
    default:
      nil
    }
  }

  var canonicalStringValue: String? {
    if let stringValue { return stringValue }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

public actor ExifToolClient: MetadataTooling {
  private let runner: any ExecutableRunning
  public let configuration: ExifToolConfiguration

  public init(
    runner: any ExecutableRunning = ProcessExecutableRunner(), configuration: ExifToolConfiguration
  ) {
    self.runner = runner
    self.configuration = configuration
  }

  public func checkVersion() async throws -> ExifToolVersion {
    let result = try await invoke(["-ver"])
    let output = String(decoding: result.standardOutput, as: UTF8.self)
    let version = try ExifToolVersion(output)
    guard version >= configuration.minimumVersion else {
      throw MetadataInfrastructureError.malformedExifToolOutput(
        "ExifTool \(version) 低于最低版本 \(configuration.minimumVersion)"
      )
    }
    return version
  }

  public func readRawMetadata(_ files: [ReadOnlyRawFile]) async throws -> [RawPhotoMetadata] {
    let mediaMetadata = try await readMediaMetadata(files.map(\.mediaFile))
    let byURL = Dictionary(uniqueKeysWithValues: mediaMetadata.map { ($0.mediaFile.url, $0) })
    return try files.map { rawFile in
      guard let metadata = byURL[rawFile.url] else {
        throw MetadataInfrastructureError.missingMetadata(rawFile.url)
      }
      return RawPhotoMetadata(mediaMetadata: metadata, rawFile: rawFile)
    }
  }

  public func readMediaMetadata(_ files: [ReadOnlyMediaFile]) async throws -> [MediaMetadata] {
    guard !files.isEmpty else { return [] }
    let arguments =
      [
        "-json", "-G1", "-a", "-s", "-struct",
        "-EXIF:DateTimeOriginal",
        "-EXIF:SubSecTimeOriginal",
        "-EXIF:OffsetTimeOriginal",
        "-EXIF:GPSLatitude#",
        "-EXIF:GPSLongitude#",
        "-EXIF:GPSAltitude#",
        "-EXIF:GPSAltitudeRef#",
        "-Make",
        "-Model",
        "-SerialNumber",
        "-InternalSerialNumber",
        "-ShutterCount#",
        "-FileSize#",
        "-GPSDateTime",
        "-GPSHPositioningError#",
        "-DocumentID",
        "-OriginalDocumentID",
        "-DerivedFrom",
        "-Software",
        "-XMPToolkit",
      ] + files.map(\.url.path)
    let objects = try await readJSON(arguments)
    var byPath: [String: [String: JSONValue]] = [:]
    for object in objects {
      guard let sourcePath = value(in: object, suffix: "SourceFile")?.stringValue else { continue }
      byPath[URL(fileURLWithPath: sourcePath).standardizedFileURL.path] = object
    }

    return try files.map { mediaFile in
      guard let object = byPath[mediaFile.url.path] else {
        throw MetadataInfrastructureError.missingMetadata(mediaFile.url)
      }
      let parsedGPS = try parsedGPS(in: object)
      return MediaMetadata(
        mediaFile: mediaFile,
        dateTimeOriginal: value(in: object, suffix: "DateTimeOriginal")?.stringValue,
        subsecondTimeOriginal: value(in: object, suffix: "SubSecTimeOriginal")?.stringValue,
        offsetTimeOriginal: value(in: object, suffix: "OffsetTimeOriginal")?.stringValue,
        gps: parsedGPS.metadata,
        gpsIsPartial: parsedGPS.isPartial,
        make: value(in: object, preferredKeys: ["IFD0:Make"], suffix: "Make")?.stringValue,
        model: value(in: object, preferredKeys: ["IFD0:Model"], suffix: "Model")?.stringValue,
        serialNumber: value(
          in: object,
          preferredKeys: ["Nikon:SerialNumber", "EXIF:SerialNumber"],
          suffix: "SerialNumber"
        )?.stringValue,
        internalSerialNumber: value(
          in: object,
          preferredKeys: ["Nikon:InternalSerialNumber"],
          suffix: "InternalSerialNumber"
        )?.stringValue,
        shutterCount: value(
          in: object,
          preferredKeys: ["Nikon:ShutterCount"],
          suffix: "ShutterCount"
        )?.int64Value.flatMap(Int.init(exactly:)),
        fileSize: value(in: object, preferredKeys: ["File:FileSize"], suffix: "FileSize")?
          .int64Value,
        gpsDateTime: value(
          in: object,
          preferredKeys: ["Composite:GPSDateTime", "EXIF:GPSDateTime"],
          suffix: "GPSDateTime"
        )?.stringValue,
        gpsHorizontalPositioningError: value(
          in: object,
          preferredKeys: ["EXIF:GPSHPositioningError"],
          suffix: "GPSHPositioningError"
        )?.doubleValue,
        documentID: value(
          in: object,
          preferredKeys: ["XMP-xmpMM:DocumentID"],
          suffix: "DocumentID"
        )?.stringValue,
        originalDocumentID: value(
          in: object,
          preferredKeys: ["XMP-xmpMM:OriginalDocumentID"],
          suffix: "OriginalDocumentID"
        )?.stringValue,
        derivedFrom: value(
          in: object,
          preferredKeys: ["XMP-xmpMM:DerivedFrom"],
          suffix: "DerivedFrom"
        )?.canonicalStringValue,
        software: value(in: object, preferredKeys: ["IFD0:Software"], suffix: "Software")?
          .stringValue,
        xmpToolkit: value(
          in: object,
          preferredKeys: ["XMP-x:XMPToolkit"],
          suffix: "XMPToolkit"
        )?.stringValue
      )
    }
  }

  public func readSidecarMetadata(at sidecar: SidecarURL) async throws -> SidecarMetadata {
    let objects = try await readJSON([
      "-json", "-G1", "-a", "-s", "-struct", "-n",
      "-XMP:All",
      "-XMP-exif:GPSLatitude#",
      "-XMP-exif:GPSLongitude#",
      "-XMP-exif:GPSAltitude#",
      "-XMP-exif:GPSAltitudeRef#",
      sidecar.url.path,
    ])
    guard var object = objects.first else {
      throw MetadataInfrastructureError.missingMetadata(sidecar.url)
    }
    let parsedGPS = try parsedGPS(in: object)
    let documentID = value(
      in: object, preferredKeys: ["XMP-xmpMM:DocumentID"], suffix: "DocumentID"
    )?.stringValue
    let originalDocumentID = value(
      in: object,
      preferredKeys: ["XMP-xmpMM:OriginalDocumentID"],
      suffix: "OriginalDocumentID"
    )?.stringValue
    let derivedFrom = value(
      in: object, preferredKeys: ["XMP-xmpMM:DerivedFrom"], suffix: "DerivedFrom"
    )?.canonicalStringValue
    let software = value(in: object, preferredKeys: ["IFD0:Software"], suffix: "Software")?
      .stringValue
    let xmpToolkit = value(
      in: object, preferredKeys: ["XMP-x:XMPToolkit"], suffix: "XMPToolkit"
    )?.stringValue
    object = object.filter { key, _ in
      !Self.ignoredForSemanticDigest(key)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(object)
    let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    return SidecarMetadata(
      gps: parsedGPS.metadata,
      gpsIsPartial: parsedGPS.isPartial,
      nonGPSSemanticDigest: digest,
      documentID: documentID,
      originalDocumentID: originalDocumentID,
      derivedFrom: derivedFrom,
      software: software,
      xmpToolkit: xmpToolkit
    )
  }

  public func writeGPS(_ gps: GPSMetadata, to sidecar: SidecarURL) async throws {
    var arguments = [
      "-overwrite_original",
      "-n",
      "-XMP-exif:GPSLatitude=\(Self.decimal(gps.latitude))",
      "-XMP-exif:GPSLongitude=\(Self.decimal(gps.longitude))",
    ]
    if let altitude = gps.altitude {
      arguments.append("-XMP-exif:GPSAltitude=\(Self.decimal(abs(altitude)))")
      arguments.append("-XMP-exif:GPSAltitudeRef=\(altitude < 0 ? 1 : 0)")
    }
    arguments.append(sidecar.url.path)
    _ = try await invoke(arguments)
  }

  private func readJSON(_ arguments: [String]) async throws -> [[String: JSONValue]] {
    let result = try await invoke(arguments)
    do {
      return try JSONDecoder().decode([[String: JSONValue]].self, from: result.standardOutput)
    } catch {
      let output = String(decoding: result.standardOutput.prefix(1_024), as: UTF8.self)
      throw MetadataInfrastructureError.malformedExifToolOutput("\(error): \(output)")
    }
  }

  private func invoke(_ arguments: [String]) async throws -> ExecutableResult {
    try Task.checkCancellation()
    let invocation = ExecutableInvocation(
      executableURL: configuration.executableURL,
      arguments: configuration.leadingArguments + arguments,
      environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    )
    let result = try await runner.run(invocation, timeout: configuration.timeout)
    guard result.terminationStatus == 0 else {
      throw MetadataInfrastructureError.executableFailed(
        status: result.terminationStatus,
        stderr: String(decoding: result.standardError, as: UTF8.self)
      )
    }
    return result
  }

  private func value(in object: [String: JSONValue], suffix: String) -> JSONValue? {
    object.first { key, _ in
      key == suffix || key.hasSuffix(":\(suffix)")
    }?.value
  }

  private func value(
    in object: [String: JSONValue],
    preferredKeys: [String],
    suffix: String
  ) -> JSONValue? {
    for key in preferredKeys {
      if let value = object[key] { return value }
    }
    return value(in: object, suffix: suffix)
  }

  private func parsedGPS(in object: [String: JSONValue]) throws -> (
    metadata: GPSMetadata?, isPartial: Bool
  ) {
    let latitude = value(in: object, suffix: "GPSLatitude")?.doubleValue
    let longitude = value(in: object, suffix: "GPSLongitude")?.doubleValue
    let rawAltitude = value(in: object, suffix: "GPSAltitude")?.doubleValue
    let altitudeReference = value(in: object, suffix: "GPSAltitudeRef")?.doubleValue
    guard let latitude, let longitude else {
      return (
        nil, latitude != nil || longitude != nil || rawAltitude != nil || altitudeReference != nil
      )
    }
    let altitude = rawAltitude.map { altitudeReference == 1 ? -abs($0) : $0 }
    return (try GPSMetadata(latitude: latitude, longitude: longitude, altitude: altitude), false)
  }

  private static func ignoredForSemanticDigest(_ key: String) -> Bool {
    let suffix = key.split(separator: ":").last.map(String.init) ?? key
    let ignored = [
      "SourceFile", "GPSLatitude", "GPSLongitude", "GPSAltitude", "GPSAltitudeRef",
      "GPSMapDatum", "GPSProcessingMethod", "GPSTimeStamp", "XMPToolkit",
    ]
    return ignored.contains(suffix)
  }

  private static func decimal(_ value: Double) -> String {
    String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
  }
}
