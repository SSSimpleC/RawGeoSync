import Foundation

public struct TrackNormalizationConfiguration: Hashable, Sendable, Codable {
  public var duplicateCoordinateToleranceMeters: Double
  public var reliableMaximumDurationSeconds: TimeInterval
  public var reliableMaximumDistanceMeters: Double
  public var reviewMaximumDurationSeconds: TimeInterval
  public var stayMinimumDurationSeconds: TimeInterval
  public var stayMaximumDurationSeconds: TimeInterval
  public var stayMaximumDisplacementMeters: Double
  public var maximumImpliedSpeedMetersPerSecond: Double
  public var spikeMaximumLegDurationSeconds: TimeInterval
  public var spikeMinimumLegDistanceMeters: Double
  public var spikeMaximumDirectDistanceMeters: Double
  public var spikeMaximumDirectDistanceRatio: Double

  public init(
    duplicateCoordinateToleranceMeters: Double = 30,
    reliableMaximumDurationSeconds: TimeInterval = 300,
    reliableMaximumDistanceMeters: Double = 2_000,
    reviewMaximumDurationSeconds: TimeInterval = 600,
    stayMinimumDurationSeconds: TimeInterval = 600,
    stayMaximumDurationSeconds: TimeInterval = 21_600,
    stayMaximumDisplacementMeters: Double = 150,
    maximumImpliedSpeedMetersPerSecond: Double = 500,
    spikeMaximumLegDurationSeconds: TimeInterval = 120,
    spikeMinimumLegDistanceMeters: Double = 500,
    spikeMaximumDirectDistanceMeters: Double = 100,
    spikeMaximumDirectDistanceRatio: Double = 0.1
  ) {
    self.duplicateCoordinateToleranceMeters = duplicateCoordinateToleranceMeters
    self.reliableMaximumDurationSeconds = reliableMaximumDurationSeconds
    self.reliableMaximumDistanceMeters = reliableMaximumDistanceMeters
    self.reviewMaximumDurationSeconds = reviewMaximumDurationSeconds
    self.stayMinimumDurationSeconds = stayMinimumDurationSeconds
    self.stayMaximumDurationSeconds = stayMaximumDurationSeconds
    self.stayMaximumDisplacementMeters = stayMaximumDisplacementMeters
    self.maximumImpliedSpeedMetersPerSecond = maximumImpliedSpeedMetersPerSecond
    self.spikeMaximumLegDurationSeconds = spikeMaximumLegDurationSeconds
    self.spikeMinimumLegDistanceMeters = spikeMinimumLegDistanceMeters
    self.spikeMaximumDirectDistanceMeters = spikeMaximumDirectDistanceMeters
    self.spikeMaximumDirectDistanceRatio = spikeMaximumDirectDistanceRatio
  }

  public static let `default` = TrackNormalizationConfiguration()
}

public struct TrackNormalizer: Sendable {
  public let configuration: TrackNormalizationConfiguration

  public init(configuration: TrackNormalizationConfiguration = .default) {
    self.configuration = configuration
  }

  public func normalize(_ document: GPXDocument) -> NormalizedTrack {
    var normalizedSegments: [NormalizedTrackSegment] = []
    var warnings: [TrackNormalizationWarning] = []
    var nextSegmentID = 0

    for sourceSegment in document.segments {
      let validPoints = sourceSegment.points.filter { point in
        let valid =
          point.coordinate.isValid && point.timestamp.timeIntervalSinceReferenceDate.isFinite
        if !valid {
          warnings.append(.invalidPoint(point.source))
        }
        return valid
      }

      let chunks = monotonicChunks(from: validPoints, warnings: &warnings)
      for chunk in chunks where !chunk.isEmpty {
        let filtered = removingIsolatedSpikes(from: chunk, warnings: &warnings)
        guard !filtered.isEmpty else { continue }
        let intervals = zip(filtered, filtered.dropFirst()).map(makeInterval)
        normalizedSegments.append(
          NormalizedTrackSegment(
            id: nextSegmentID,
            sourceTrackIndex: sourceSegment.trackIndex,
            sourceSegmentIndex: sourceSegment.segmentIndex,
            points: filtered,
            intervals: intervals
          )
        )
        nextSegmentID += 1
      }
    }

    return NormalizedTrack(segments: normalizedSegments, warnings: warnings)
  }

  private func monotonicChunks(
    from points: [TrackPoint],
    warnings: inout [TrackNormalizationWarning]
  ) -> [[TrackPoint]] {
    var chunks: [[TrackPoint]] = []
    var current: [TrackPoint] = []

    for point in points {
      guard let previous = current.last else {
        current.append(point)
        continue
      }

      let delta = point.timestamp.timeIntervalSince(previous.timestamp)
      if delta > 0 {
        current.append(point)
      } else if delta == 0 {
        let distance = GeoMath.distance(from: previous.coordinate, to: point.coordinate)
        if distance <= configuration.duplicateCoordinateToleranceMeters {
          warnings.append(.duplicatePointCollapsed(kept: previous.source, removed: point.source))
        } else {
          warnings.append(
            .conflictingDuplicateTimestamp(first: previous.source, second: point.source)
          )
          chunks.append(current)
          current = [point]
        }
      } else {
        warnings.append(.reversedTimestamp(previous: previous.source, next: point.source))
        chunks.append(current)
        current = [point]
      }
    }

    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }

  private func removingIsolatedSpikes(
    from points: [TrackPoint],
    warnings: inout [TrackNormalizationWarning]
  ) -> [TrackPoint] {
    guard points.count >= 3 else { return points }
    var result: [TrackPoint] = [points[0]]

    for index in 1..<(points.count - 1) {
      let first = result.last!
      let candidate = points[index]
      let third = points[index + 1]
      if isIsolatedSpike(first, candidate, third) {
        warnings.append(.isolatedSpatialSpikeRemoved(candidate.source))
      } else {
        result.append(candidate)
      }
    }
    result.append(points[points.count - 1])
    return result
  }

  private func isIsolatedSpike(_ first: TrackPoint, _ middle: TrackPoint, _ last: TrackPoint)
    -> Bool
  {
    let firstDuration = middle.timestamp.timeIntervalSince(first.timestamp)
    let secondDuration = last.timestamp.timeIntervalSince(middle.timestamp)
    guard firstDuration > 0,
      secondDuration > 0,
      firstDuration <= configuration.spikeMaximumLegDurationSeconds,
      secondDuration <= configuration.spikeMaximumLegDurationSeconds
    else {
      return false
    }

    let firstLeg = GeoMath.distance(from: first.coordinate, to: middle.coordinate)
    let secondLeg = GeoMath.distance(from: middle.coordinate, to: last.coordinate)
    let direct = GeoMath.distance(from: first.coordinate, to: last.coordinate)
    guard firstLeg >= configuration.spikeMinimumLegDistanceMeters,
      secondLeg >= configuration.spikeMinimumLegDistanceMeters
    else {
      return false
    }
    let allowedDirectDistance = max(
      configuration.spikeMaximumDirectDistanceMeters,
      (firstLeg + secondLeg) * configuration.spikeMaximumDirectDistanceRatio
    )
    return direct <= allowedDirectDistance
  }

  private func makeInterval(start: TrackPoint, end: TrackPoint) -> TrackInterval {
    let duration = end.timestamp.timeIntervalSince(start.timestamp)
    let distance = GeoMath.distance(from: start.coordinate, to: end.coordinate)
    let speed = distance / duration
    let kind: TrackIntervalKind
    let reason: TrackIntervalReason

    if speed > configuration.maximumImpliedSpeedMetersPerSecond {
      kind = .gap
      reason = .excessiveImpliedSpeed
    } else if duration <= configuration.reliableMaximumDurationSeconds,
      distance <= configuration.reliableMaximumDistanceMeters
    {
      kind = .reliableInterpolation
      reason = .shortDenseInterval
    } else if duration <= configuration.reviewMaximumDurationSeconds {
      kind = .reviewInterpolation
      reason = .sparseOrLongDistanceInterval
    } else if duration > configuration.stayMinimumDurationSeconds,
      duration <= configuration.stayMaximumDurationSeconds,
      distance <= configuration.stayMaximumDisplacementMeters
    {
      kind = .stayCandidate
      reason = .longSmallDisplacement
    } else {
      kind = .gap
      reason = .longMissingCoverage
    }

    return TrackInterval(
      start: start,
      end: end,
      durationSeconds: duration,
      distanceMeters: distance,
      impliedSpeedMetersPerSecond: speed,
      kind: kind,
      reason: reason
    )
  }
}
