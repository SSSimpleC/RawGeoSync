import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

public enum GPXParseError: Error, Hashable, Sendable {
  case unreadableInput
  case cancelled
  case malformedXML(String)
}

public struct GPXStreamParser: Sendable {
  public init() {}

  public func parse(url: URL) throws -> GPXDocument {
    guard let stream = InputStream(url: url) else {
      throw GPXParseError.unreadableInput
    }
    return try parse(parser: XMLParser(stream: stream))
  }

  public func parse(data: Data) throws -> GPXDocument {
    try parse(parser: XMLParser(data: data))
  }

  private func parse(parser: XMLParser) throws -> GPXDocument {
    let delegate = ParserDelegate()
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
      if delegate.wasCancelled {
        throw GPXParseError.cancelled
      }
      throw GPXParseError.malformedXML(
        parser.parserError?.localizedDescription ?? "Unknown XML error")
    }
    return delegate.document
  }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
  private(set) var wasCancelled = false
  private struct PointBuilder {
    let source: TrackPointSource
    let latitudeText: String?
    let longitudeText: String?
    var timestampText: String?
    var elevationText: String?
    var horizontalAccuracyText: String?
    var speedText: String?
    var courseText: String?
  }

  private(set) var version: String?
  private(set) var creator: String?
  private(set) var segments: [GPXTrackSegment] = []
  private(set) var warnings: [GPXWarning] = []

  private var trackIndex = -1
  private var segmentIndex = -1
  private var pointIndex = 0
  private var isInsideSegment = false
  private var currentPoints: [TrackPoint] = []
  private var currentPoint: PointBuilder?
  private var currentTextElement: String?
  private var textBuffer = ""

  private let fractionalDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  var document: GPXDocument {
    var warnings = warnings
    if let version, version != "1.0", version != "1.1" {
      warnings.insert(.unsupportedVersion(version), at: 0)
    }
    return GPXDocument(version: version, creator: creator, segments: segments, warnings: warnings)
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    if Task.isCancelled {
      wasCancelled = true
      parser.abortParsing()
      return
    }
    let name = localName(elementName)
    switch name {
    case "gpx":
      version = attributeDict["version"]
      creator = attributeDict["creator"]
    case "trk":
      trackIndex += 1
      segmentIndex = -1
    case "trkseg":
      segmentIndex += 1
      pointIndex = 0
      currentPoints = []
      isInsideSegment = true
    case "trkpt":
      guard isInsideSegment else {
        warnings.append(.pointOutsideSegment(pointIndex: pointIndex))
        pointIndex += 1
        return
      }
      currentPoint = PointBuilder(
        source: TrackPointSource(
          trackIndex: max(trackIndex, 0),
          segmentIndex: max(segmentIndex, 0),
          pointIndex: pointIndex
        ),
        latitudeText: attributeDict["lat"],
        longitudeText: attributeDict["lon"]
      )
      pointIndex += 1
    case "time", "ele", "speed", "course", "horizontalAccuracy", "hAcc", "accuracy":
      guard currentPoint != nil else { return }
      currentTextElement = name
      textBuffer = ""
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard currentTextElement != nil else { return }
    textBuffer += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = localName(elementName)
    if name == currentTextElement {
      let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
      switch name {
      case "time": currentPoint?.timestampText = value
      case "ele": currentPoint?.elevationText = value
      case "speed": currentPoint?.speedText = value
      case "course": currentPoint?.courseText = value
      case "horizontalAccuracy", "hAcc", "accuracy": currentPoint?.horizontalAccuracyText = value
      default: break
      }
      currentTextElement = nil
      textBuffer = ""
    }

    switch name {
    case "trkpt":
      finishCurrentPoint()
    case "trkseg":
      segments.append(
        GPXTrackSegment(
          trackIndex: max(trackIndex, 0),
          segmentIndex: max(segmentIndex, 0),
          points: currentPoints
        )
      )
      currentPoints = []
      isInsideSegment = false
    default:
      break
    }
  }

  private func finishCurrentPoint() {
    guard let point = currentPoint else { return }
    currentPoint = nil

    guard let latitudeText = point.latitudeText,
      let longitudeText = point.longitudeText,
      let latitude = Double(latitudeText),
      let longitude = Double(longitudeText),
      GeoCoordinate(latitude: latitude, longitude: longitude).isValid
    else {
      warnings.append(
        .pointHasInvalidCoordinate(
          trackIndex: point.source.trackIndex,
          segmentIndex: point.source.segmentIndex,
          pointIndex: point.source.pointIndex
        )
      )
      return
    }

    guard let timestampText = point.timestampText else {
      warnings.append(
        .pointMissingTimestamp(
          trackIndex: point.source.trackIndex,
          segmentIndex: point.source.segmentIndex,
          pointIndex: point.source.pointIndex
        )
      )
      return
    }
    guard
      let timestamp = fractionalDateFormatter.date(from: timestampText)
        ?? dateFormatter.date(from: timestampText)
    else {
      warnings.append(
        .pointHasInvalidTimestamp(
          trackIndex: point.source.trackIndex,
          segmentIndex: point.source.segmentIndex,
          pointIndex: point.source.pointIndex,
          value: timestampText
        )
      )
      return
    }

    let speed = point.speedText.flatMap(Double.init).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
    let accuracy = point.horizontalAccuracyText.flatMap(Double.init).flatMap {
      $0 >= 0 && $0.isFinite ? $0 : nil
    }
    currentPoints.append(
      TrackPoint(
        timestamp: timestamp,
        coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
        elevationMeters: finiteDouble(point.elevationText),
        horizontalAccuracyMeters: accuracy,
        speedMetersPerSecond: speed,
        courseDegrees: finiteDouble(point.courseText),
        source: point.source
      )
    )
  }

  private func finiteDouble(_ value: String?) -> Double? {
    guard let value, let number = Double(value), number.isFinite else { return nil }
    return number
  }

  private func localName(_ name: String) -> String {
    String(name.split(separator: ":").last ?? Substring(name))
  }
}
