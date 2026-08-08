import Foundation

@testable import RawGeoCore

func isoDate(_ value: String) -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: value) { return date }
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: value)!
}

func point(
  _ seconds: TimeInterval,
  latitude: Double,
  longitude: Double,
  sourceIndex: Int,
  segmentIndex: Int = 0,
  elevation: Double? = nil,
  accuracy: Double? = nil,
  speed: Double? = nil
) -> TrackPoint {
  TrackPoint(
    timestamp: Date(timeIntervalSince1970: seconds),
    coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
    elevationMeters: elevation,
    horizontalAccuracyMeters: accuracy,
    speedMetersPerSecond: speed,
    source: TrackPointSource(trackIndex: 0, segmentIndex: segmentIndex, pointIndex: sourceIndex)
  )
}

func normalizedTrack(_ segments: [GPXTrackSegment]) -> NormalizedTrack {
  TrackNormalizer().normalize(
    GPXDocument(version: "1.1", creator: "Tests", segments: segments)
  )
}
