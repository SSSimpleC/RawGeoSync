import Foundation

public struct GeoMatcherConfiguration: Hashable, Sendable, Codable {
  public var exactToleranceSeconds: TimeInterval
  public var nearestToleranceSeconds: TimeInterval
  public var agreeingCandidateDistanceMeters: Double

  public init(
    exactToleranceSeconds: TimeInterval = 2,
    nearestToleranceSeconds: TimeInterval = 120,
    agreeingCandidateDistanceMeters: Double = 150
  ) {
    self.exactToleranceSeconds = exactToleranceSeconds
    self.nearestToleranceSeconds = nearestToleranceSeconds
    self.agreeingCandidateDistanceMeters = agreeingCandidateDistanceMeters
  }

  public static let `default` = GeoMatcherConfiguration()
}

public struct GeoMatcher: Sendable {
  public let configuration: GeoMatcherConfiguration

  public init(configuration: GeoMatcherConfiguration = .default) {
    self.configuration = configuration
  }

  public func match(photos: [PhotoCapture], track: NormalizedTrack) -> [PhotoMatchResult] {
    photos.map { photo in
      let candidates = track.segments.flatMap { makeCandidates(for: photo, in: $0) }
      return resolve(photo: photo, candidates: candidates)
    }
  }

  private func makeCandidates(
    for photo: PhotoCapture,
    in segment: NormalizedTrackSegment
  ) -> [MatchCandidate] {
    guard !segment.points.isEmpty else { return [] }
    let insertionIndex = firstIndexAtOrAfter(photo.captureTimeUTC, in: segment.points)

    var exactPoints: [TrackPoint] = []
    if insertionIndex < segment.points.count {
      exactPoints.append(segment.points[insertionIndex])
    }
    if insertionIndex > 0 {
      exactPoints.append(segment.points[insertionIndex - 1])
    }
    if let exact =
      exactPoints
      .filter({
        abs($0.timestamp.timeIntervalSince(photo.captureTimeUTC))
          <= configuration.exactToleranceSeconds
      })
      .sorted(by: { first, second in
        let firstDelta = abs(first.timestamp.timeIntervalSince(photo.captureTimeUTC))
        let secondDelta = abs(second.timestamp.timeIntervalSince(photo.captureTimeUTC))
        if firstDelta != secondDelta { return firstDelta < secondDelta }
        return first.source.pointIndex < second.source.pointIndex
      })
      .first
    {
      return [
        MatchCandidate(
          segmentID: segment.id,
          mode: .exact,
          confidence: .reliable,
          coordinate: exact.coordinate,
          elevationMeters: exact.elevationMeters,
          startPoint: exact,
          endPoint: nil,
          reason: .exactTrackPoint
        )
      ]
    }

    if insertionIndex == 0 {
      return endpointCandidate(
        point: segment.points[0],
        photo: photo,
        segmentID: segment.id,
        reason: .outsideTrackNearest
      )
    }
    if insertionIndex == segment.points.count {
      return endpointCandidate(
        point: segment.points[segment.points.count - 1],
        photo: photo,
        segmentID: segment.id,
        reason: .outsideTrackNearest
      )
    }

    let interval = segment.intervals[insertionIndex - 1]
    let fraction =
      photo.captureTimeUTC.timeIntervalSince(interval.start.timestamp)
      / interval.durationSeconds
    switch interval.kind {
    case .reliableInterpolation:
      return [
        interpolationCandidate(
          interval: interval,
          fraction: fraction,
          segmentID: segment.id,
          mode: .reliableInterpolation,
          confidence: .reliable,
          reason: .shortBracketingInterval,
          includeElevation: true
        )
      ]
    case .reviewInterpolation:
      return [
        interpolationCandidate(
          interval: interval,
          fraction: fraction,
          segmentID: segment.id,
          mode: .reviewInterpolation,
          confidence: .review,
          reason: .sparseBracketingInterval,
          includeElevation: false
        )
      ]
    case .stayCandidate:
      return [
        MatchCandidate(
          segmentID: segment.id,
          mode: .stayCandidate,
          confidence: .review,
          coordinate: interval.start.coordinate,
          elevationMeters: nil,
          startPoint: interval.start,
          endPoint: interval.end,
          reason: .stationaryGapCandidate
        )
      ]
    case .gap:
      return nearestBoundaryCandidates(
        interval: interval,
        photo: photo,
        segmentID: segment.id
      )
    }
  }

  private func interpolationCandidate(
    interval: TrackInterval,
    fraction: Double,
    segmentID: Int,
    mode: MatchMode,
    confidence: MatchConfidence,
    reason: MatchReasonCode,
    includeElevation: Bool
  ) -> MatchCandidate {
    let elevation: Double?
    if includeElevation,
      let startElevation = interval.start.elevationMeters,
      let endElevation = interval.end.elevationMeters
    {
      elevation = startElevation + (endElevation - startElevation) * fraction
    } else {
      elevation = nil
    }
    return MatchCandidate(
      segmentID: segmentID,
      mode: mode,
      confidence: confidence,
      coordinate: GeoMath.interpolate(
        from: interval.start.coordinate,
        to: interval.end.coordinate,
        fraction: fraction
      ),
      elevationMeters: elevation,
      startPoint: interval.start,
      endPoint: interval.end,
      reason: reason
    )
  }

  private func nearestBoundaryCandidates(
    interval: TrackInterval,
    photo: PhotoCapture,
    segmentID: Int
  ) -> [MatchCandidate] {
    let startDelta = abs(photo.captureTimeUTC.timeIntervalSince(interval.start.timestamp))
    let endDelta = abs(photo.captureTimeUTC.timeIntervalSince(interval.end.timestamp))
    let minimum = min(startDelta, endDelta)
    guard minimum <= configuration.nearestToleranceSeconds else { return [] }

    if startDelta == endDelta {
      return [interval.start, interval.end].map {
        MatchCandidate(
          segmentID: segmentID,
          mode: .nearest,
          confidence: .review,
          coordinate: $0.coordinate,
          elevationMeters: $0.elevationMeters,
          startPoint: $0,
          endPoint: nil,
          reason: .gapBoundaryNearest
        )
      }
    }
    let selected = startDelta < endDelta ? interval.start : interval.end
    return [
      MatchCandidate(
        segmentID: segmentID,
        mode: .nearest,
        confidence: .review,
        coordinate: selected.coordinate,
        elevationMeters: selected.elevationMeters,
        startPoint: selected,
        endPoint: nil,
        reason: .gapBoundaryNearest
      )
    ]
  }

  private func endpointCandidate(
    point: TrackPoint,
    photo: PhotoCapture,
    segmentID: Int,
    reason: MatchReasonCode
  ) -> [MatchCandidate] {
    guard
      abs(photo.captureTimeUTC.timeIntervalSince(point.timestamp))
        <= configuration.nearestToleranceSeconds
    else {
      return []
    }
    return [
      MatchCandidate(
        segmentID: segmentID,
        mode: .nearest,
        confidence: .review,
        coordinate: point.coordinate,
        elevationMeters: point.elevationMeters,
        startPoint: point,
        endPoint: nil,
        reason: reason
      )
    ]
  }

  private func resolve(photo: PhotoCapture, candidates: [MatchCandidate]) -> PhotoMatchResult {
    guard !candidates.isEmpty else {
      return PhotoMatchResult(
        photo: photo,
        mode: .unmatched,
        confidence: .unmatched,
        coordinate: nil,
        elevationMeters: nil,
        sensorAccuracy: .unknown,
        requiresConfirmation: false,
        reasonCodes: [.noTrackCoverage],
        candidates: []
      )
    }

    if candidates.count == 1, let candidate = candidates.first {
      return result(photo: photo, candidate: candidate, allCandidates: candidates)
    }

    let candidatesAgree = candidates.indices.allSatisfy { firstIndex in
      candidates.indices.allSatisfy { secondIndex in
        GeoMath.distance(
          from: candidates[firstIndex].coordinate,
          to: candidates[secondIndex].coordinate
        ) <= configuration.agreeingCandidateDistanceMeters
      }
    }

    guard candidatesAgree else {
      return PhotoMatchResult(
        photo: photo,
        mode: .ambiguous,
        confidence: .review,
        coordinate: nil,
        elevationMeters: nil,
        sensorAccuracy: .unknown,
        requiresConfirmation: true,
        reasonCodes: [.conflictingTracks],
        candidates: candidates
      )
    }

    let selected = candidates.sorted(by: candidatePrecedes).first!
    return PhotoMatchResult(
      photo: photo,
      mode: selected.mode,
      confidence: .review,
      coordinate: selected.coordinate,
      elevationMeters: selected.elevationMeters,
      sensorAccuracy: sensorAccuracy(for: selected),
      requiresConfirmation: true,
      reasonCodes: [selected.reason, .agreeingTracks],
      candidates: candidates
    )
  }

  private func result(
    photo: PhotoCapture,
    candidate: MatchCandidate,
    allCandidates: [MatchCandidate]
  ) -> PhotoMatchResult {
    PhotoMatchResult(
      photo: photo,
      mode: candidate.mode,
      confidence: candidate.confidence,
      coordinate: candidate.coordinate,
      elevationMeters: candidate.elevationMeters,
      sensorAccuracy: sensorAccuracy(for: candidate),
      requiresConfirmation: candidate.confidence != .reliable,
      reasonCodes: [candidate.reason],
      candidates: allCandidates
    )
  }

  private func sensorAccuracy(for candidate: MatchCandidate) -> SensorAccuracy {
    let values = [
      candidate.startPoint.horizontalAccuracyMeters,
      candidate.endPoint?.horizontalAccuracyMeters,
    ].compactMap { $0 }
    let expectedCount = candidate.endPoint == nil ? 1 : 2
    guard values.count == expectedCount, let conservativeValue = values.max() else {
      return .unknown
    }
    return .known(meters: conservativeValue)
  }

  private func candidatePrecedes(_ first: MatchCandidate, _ second: MatchCandidate) -> Bool {
    let firstRank = first.confidence == .reliable ? 0 : 1
    let secondRank = second.confidence == .reliable ? 0 : 1
    if firstRank != secondRank { return firstRank < secondRank }
    if first.segmentID != second.segmentID { return first.segmentID < second.segmentID }
    return first.startPoint.source.pointIndex < second.startPoint.source.pointIndex
  }

  private func firstIndexAtOrAfter(_ date: Date, in points: [TrackPoint]) -> Int {
    var lowerBound = 0
    var upperBound = points.count
    while lowerBound < upperBound {
      let middle = (lowerBound + upperBound) / 2
      if points[middle].timestamp < date {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    return lowerBound
  }
}
