import Foundation

/// Splits logical trajectory sources into matchable sessions. Missing coverage and
/// flight-speed legs are explicit relations, so no interpolation crosses them.
public struct TrajectoryCorpusBuilder: Sendable {
  public let policy: LocationRulePolicy

  public init(policy: LocationRulePolicy = .v2) {
    self.policy = policy
  }

  public func build(sources: [TrajectoryLogicalSource]) -> TrajectoryCorpus {
    let sortedSources = sources.sorted {
      if $0.priority != $1.priority { return $0.priority < $1.priority }
      return $0.id.rawValue < $1.id.rawValue
    }
    var allSessions: [TrajectorySession] = []
    var allRelations: [TrajectoryRelation] = []

    for source in sortedSources {
      let result = sessions(for: source)
      allSessions.append(contentsOf: result.sessions)
      allRelations.append(contentsOf: result.relations)
    }

    allSessions.sort(by: sessionOrder)
    allRelations.sort { $0.id < $1.id }
    return TrajectoryCorpus(
      sources: sortedSources,
      sessions: allSessions,
      relations: allRelations
    )
  }

  private func sessions(for source: TrajectoryLogicalSource) -> (
    sessions: [TrajectorySession], relations: [TrajectoryRelation]
  ) {
    let segments = source.track.segments.sorted {
      let left = $0.points.first?.timestamp ?? .distantFuture
      let right = $1.points.first?.timestamp ?? .distantFuture
      if left != right { return left < right }
      return $0.id < $1.id
    }
    var sessions: [TrajectorySession] = []
    var relations: [TrajectoryRelation] = []
    var previousSegmentLastSession: TrajectorySession?

    for segment in segments where !segment.points.isEmpty {
      var segmentSessions: [TrajectorySession] = []
      var currentPoints = [segment.points[0]]
      var currentIntervals: [TrackInterval] = []
      var runIndex = 0

      func makeSession() -> TrajectorySession {
        TrajectorySession(
          id: "\(source.id.rawValue)#\(segment.id).\(runIndex)",
          sourceID: source.id,
          sourceKind: source.kind,
          sourcePriority: source.priority,
          sourceSegmentID: segment.id,
          points: currentPoints,
          intervals: currentIntervals,
          mobility: .ground
        )
      }

      for interval in segment.intervals {
        let boundaryKind: TrajectoryRelationKind?
        if interval.impliedSpeedMetersPerSecond
          >= policy.flightBoundarySpeedMetersPerSecond
        {
          boundaryKind = .flightBoundary
        } else if interval.kind == .gap {
          boundaryKind = .missingCoverage
        } else {
          boundaryKind = nil
        }

        guard let boundaryKind else {
          currentIntervals.append(interval)
          currentPoints.append(interval.end)
          continue
        }

        let left = makeSession()
        segmentSessions.append(left)
        runIndex += 1
        currentPoints = [interval.end]
        currentIntervals = []
        let rightID = "\(source.id.rawValue)#\(segment.id).\(runIndex)"
        relations.append(
          relation(
            sourceID: source.id,
            leftSessionID: left.id,
            rightSessionID: rightID,
            kind: boundaryKind,
            start: interval.start,
            end: interval.end
          )
        )
      }

      let last = makeSession()
      segmentSessions.append(last)

      if let previous = previousSegmentLastSession,
        let next = segmentSessions.first,
        let previousPoint = previous.points.last,
        let nextPoint = next.points.first
      {
        relations.append(
          relation(
            sourceID: source.id,
            leftSessionID: previous.id,
            rightSessionID: next.id,
            kind: .sourceSegmentBoundary,
            start: previousPoint,
            end: nextPoint
          )
        )
      }

      sessions.append(contentsOf: segmentSessions)
      previousSegmentLastSession = segmentSessions.last
    }

    return (sessions, relations)
  }

  private func relation(
    sourceID: TrajectorySourceID,
    leftSessionID: String,
    rightSessionID: String,
    kind: TrajectoryRelationKind,
    start: TrackPoint,
    end: TrackPoint
  ) -> TrajectoryRelation {
    let duration = end.timestamp.timeIntervalSince(start.timestamp)
    let distance = GeoMath.distance(from: start.coordinate, to: end.coordinate)
    return TrajectoryRelation(
      id: "\(sourceID.rawValue):\(leftSessionID)>\(rightSessionID):\(kind.rawValue)",
      sourceID: sourceID,
      leftSessionID: leftSessionID,
      rightSessionID: rightSessionID,
      kind: kind,
      durationSeconds: duration,
      distanceMeters: distance,
      impliedSpeedMetersPerSecond: duration > 0 ? distance / duration : nil
    )
  }

  private func sessionOrder(_ left: TrajectorySession, _ right: TrajectorySession) -> Bool {
    let leftTime = left.startTimeUTC ?? .distantFuture
    let rightTime = right.startTimeUTC ?? .distantFuture
    if leftTime != rightTime { return leftTime < rightTime }
    if left.sourcePriority != right.sourcePriority {
      return left.sourcePriority < right.sourcePriority
    }
    return left.id < right.id
  }
}

/// Converts de-duplicated embedded camera fixes into a sparse logical track.
/// Fix time, not photo capture time, is the trajectory timestamp.
public struct EmbeddedFixTrajectoryBuilder: Sendable {
  public let normalizer: TrackNormalizer

  public init(normalizer: TrackNormalizer = TrackNormalizer()) {
    self.normalizer = normalizer
  }

  public func makeSource(
    id: TrajectorySourceID,
    displayName: String? = nil,
    priority: Int = 200,
    observations: [AssetLocationObservation]
  ) -> TrajectoryLogicalSource? {
    let eligible = observations.filter {
      $0.kind == .cameraEmbedded
        && $0.coordinate.isValid
        && $0.gpsTimestampUTC != nil
    }
    let sorted = eligible.sorted {
      let leftTime = $0.gpsTimestampUTC ?? .distantFuture
      let rightTime = $1.gpsTimestampUTC ?? .distantFuture
      if leftTime != rightTime { return leftTime < rightTime }
      return $0.id < $1.id
    }

    var seen: Set<FixKey> = []
    var points: [TrackPoint] = []
    for observation in sorted {
      guard let timestamp = observation.gpsTimestampUTC else { continue }
      let key = FixKey(timestamp: timestamp, coordinate: observation.coordinate)
      guard seen.insert(key).inserted else { continue }
      points.append(
        TrackPoint(
          timestamp: timestamp,
          coordinate: observation.coordinate,
          elevationMeters: observation.elevationMeters,
          horizontalAccuracyMeters: observation.horizontalAccuracyMeters,
          source: TrackPointSource(trackIndex: 0, segmentIndex: 0, pointIndex: points.count)
        )
      )
    }
    guard !points.isEmpty else { return nil }

    let document = GPXDocument(
      version: nil,
      creator: "RawGeoCore.EmbeddedFixTrajectoryBuilder",
      segments: [GPXTrackSegment(trackIndex: 0, segmentIndex: 0, points: points)]
    )
    return TrajectoryLogicalSource(
      id: id,
      displayName: displayName,
      kind: .embeddedCameraFixes,
      priority: priority,
      track: normalizer.normalize(document)
    )
  }

  private struct FixKey: Hashable {
    let timestampMilliseconds: Int64
    let latitudeNanodegrees: Int64
    let longitudeNanodegrees: Int64

    init(timestamp: Date, coordinate: GeoCoordinate) {
      timestampMilliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
      latitudeNanodegrees = Int64((coordinate.latitude * 1_000_000_000).rounded())
      longitudeNanodegrees = Int64((coordinate.longitude * 1_000_000_000).rounded())
    }
  }
}
