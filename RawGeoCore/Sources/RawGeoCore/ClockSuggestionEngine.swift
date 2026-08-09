import Foundation

/// Produces advisory clock corrections only. Callers must explicitly accept a
/// suggestion before applying it to capture-time normalization.
public struct ClockSuggestionEngine: Sendable {
  public let minimumEvidenceCount: Int
  public let maximumReferenceAccuracySeconds: TimeInterval

  public init(
    minimumEvidenceCount: Int = 3,
    maximumReferenceAccuracySeconds: TimeInterval = 60
  ) {
    self.minimumEvidenceCount = minimumEvidenceCount
    self.maximumReferenceAccuracySeconds = maximumReferenceAccuracySeconds
  }

  public func suggest(from observations: [ClockReferenceObservation]) -> [ClockSuggestion] {
    let eligible = observations.filter {
      ($0.referenceAccuracySeconds ?? 0) <= maximumReferenceAccuracySeconds
    }
    let grouped = Dictionary(grouping: eligible, by: \.cameraID)
    return grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { cameraID in
      suggestion(cameraID: cameraID, observations: grouped[cameraID, default: []])
    }
  }

  private func suggestion(
    cameraID: CameraID,
    observations: [ClockReferenceObservation]
  ) -> ClockSuggestion? {
    guard observations.count >= minimumEvidenceCount else { return nil }
    let samples = observations.map { observation in
      Sample(
        observation: observation,
        delta: observation.cameraCaptureTimeUTC.timeIntervalSince(observation.referenceTimeUTC)
      )
    }
    let initialMedian = median(samples.map(\.delta))
    let initialMAD = median(samples.map { abs($0.delta - initialMedian) })
    let robustSigma = initialMAD * 1.4826
    let rejectionThreshold = max(30, robustSigma * 3)
    let accepted = samples.filter { abs($0.delta - initialMedian) <= rejectionThreshold }
    guard accepted.count >= minimumEvidenceCount else { return nil }

    let finalMedian = median(accepted.map(\.delta))
    let residual = median(accepted.map { abs($0.delta - finalMedian) })
    let confidence: ClockSuggestionConfidence
    if accepted.count >= 10, residual <= 2 {
      confidence = .high
    } else if residual <= 10 {
      confidence = .medium
    } else {
      confidence = .low
    }

    return ClockSuggestion(
      cameraID: cameraID,
      cameraAheadBySeconds: finalMedian,
      confidence: confidence,
      evidenceCount: accepted.count,
      rejectedOutlierCount: samples.count - accepted.count,
      medianAbsoluteResidualSeconds: residual,
      method: .robustMedian,
      evidenceIDs: accepted.map(\.observation.id).sorted()
    )
  }

  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  private struct Sample: Sendable {
    let observation: ClockReferenceObservation
    let delta: TimeInterval
  }
}
