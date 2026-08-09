import Foundation

// MARK: - Assets and cameras

public struct CaptureAssetID: RawRepresentable, Hashable, Sendable, Codable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String { rawValue }
}

public struct CameraID: RawRepresentable, Hashable, Sendable, Codable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String { rawValue }
}

public struct ActivityID: RawRepresentable, Hashable, Sendable, Codable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String { rawValue }
}

public struct CameraIdentity: Hashable, Sendable, Codable, Identifiable {
  public let id: CameraID
  public let make: String?
  public let model: String?
  public let serialNumber: String?
  public let internalSerialNumber: String?

  public init(
    id: CameraID,
    make: String? = nil,
    model: String? = nil,
    serialNumber: String? = nil,
    internalSerialNumber: String? = nil
  ) {
    self.id = id
    self.make = make
    self.model = model
    self.serialNumber = serialNumber
    self.internalSerialNumber = internalSerialNumber
  }
}

public enum CaptureAssetKind: String, Hashable, Sendable, Codable {
  case raw
  case originalDNG
  case derivedDNG
  case rendered
  case sidecar
}

public enum CaptureTimePrecision: String, Hashable, Sendable, Codable {
  case subsecond
  case second
}

public struct CaptureAsset: Hashable, Sendable, Codable, Identifiable {
  public let id: CaptureAssetID
  public let relativePath: String
  public let kind: CaptureAssetKind
  public let activityID: ActivityID?
  public let camera: CameraIdentity?
  public let captureTimeUTC: Date
  public let captureTimePrecision: CaptureTimePrecision
  public let sequenceNumber: Int?
  public let shutterCount: Int?

  public init(
    id: CaptureAssetID,
    relativePath: String,
    kind: CaptureAssetKind = .raw,
    activityID: ActivityID? = nil,
    camera: CameraIdentity? = nil,
    captureTimeUTC: Date,
    captureTimePrecision: CaptureTimePrecision = .second,
    sequenceNumber: Int? = nil,
    shutterCount: Int? = nil
  ) {
    self.id = id
    self.relativePath = relativePath
    self.kind = kind
    self.activityID = activityID
    self.camera = camera
    self.captureTimeUTC = captureTimeUTC
    self.captureTimePrecision = captureTimePrecision
    self.sequenceNumber = sequenceNumber
    self.shutterCount = shutterCount
  }
}

public enum AssetRelationKind: String, Hashable, Sendable, Codable {
  case sameAsset
  case derivedFrom
  case sidecarOf
}

public struct AssetRelation: Hashable, Sendable, Codable, Identifiable {
  public let id: String
  public let sourceAssetID: CaptureAssetID
  public let targetAssetID: CaptureAssetID
  public let kind: AssetRelationKind

  public init(
    id: String,
    sourceAssetID: CaptureAssetID,
    targetAssetID: CaptureAssetID,
    kind: AssetRelationKind
  ) {
    self.id = id
    self.sourceAssetID = sourceAssetID
    self.targetAssetID = targetAssetID
    self.kind = kind
  }
}

// MARK: - Observations and regions

public enum AssetLocationObservationKind: String, Hashable, Sendable, Codable {
  case directSensor
  case cameraEmbedded
  case sidecar
  case renderedDerivative
  case manual
}

public struct AssetLocationObservation: Hashable, Sendable, Codable, Identifiable {
  public let id: String
  public let assetID: CaptureAssetID
  public let coordinate: GeoCoordinate
  public let elevationMeters: Double?
  public let observedAtUTC: Date?
  public let gpsTimestampUTC: Date?
  public let horizontalAccuracyMeters: Double?
  public let kind: AssetLocationObservationKind
  public let isCircular: Bool

  public init(
    id: String,
    assetID: CaptureAssetID,
    coordinate: GeoCoordinate,
    elevationMeters: Double? = nil,
    observedAtUTC: Date? = nil,
    gpsTimestampUTC: Date? = nil,
    horizontalAccuracyMeters: Double? = nil,
    kind: AssetLocationObservationKind,
    isCircular: Bool = false
  ) {
    self.id = id
    self.assetID = assetID
    self.coordinate = coordinate
    self.elevationMeters = elevationMeters
    self.observedAtUTC = observedAtUTC
    self.gpsTimestampUTC = gpsTimestampUTC
    self.horizontalAccuracyMeters = horizontalAccuracyMeters
    self.kind = kind
    self.isCircular = isCircular
  }
}

public enum ActivityRegionSource: String, Hashable, Sendable, Codable {
  case userPin
  case placeName
  case learned
}

public struct ActivityRegion: Hashable, Sendable, Codable, Identifiable {
  public let id: String
  public let activityID: ActivityID
  public let coordinate: GeoCoordinate
  public let radiusMeters: Double
  public let source: ActivityRegionSource
  public let label: String?
  public let activeFromUTC: Date?
  public let activeToUTC: Date?

  public init(
    id: String,
    activityID: ActivityID,
    coordinate: GeoCoordinate,
    radiusMeters: Double,
    source: ActivityRegionSource,
    label: String? = nil,
    activeFromUTC: Date? = nil,
    activeToUTC: Date? = nil
  ) {
    self.id = id
    self.activityID = activityID
    self.coordinate = coordinate
    self.radiusMeters = radiusMeters
    self.source = source
    self.label = label
    self.activeFromUTC = activeFromUTC
    self.activeToUTC = activeToUTC
  }

  public func contains(_ timestamp: Date) -> Bool {
    if let activeFromUTC, timestamp < activeFromUTC { return false }
    if let activeToUTC, timestamp > activeToUTC { return false }
    return true
  }
}

// MARK: - Trajectory corpus

public struct TrajectorySourceID: RawRepresentable, Hashable, Sendable, Codable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String { rawValue }
}

public enum TrajectorySourceKind: String, Hashable, Sendable, Codable {
  case gpx
  case embeddedCameraFixes
  case directSensorTrack
  case manualTrack
}

public struct TrajectoryLogicalSource: Hashable, Sendable, Codable, Identifiable {
  public let id: TrajectorySourceID
  public let displayName: String?
  public let kind: TrajectorySourceKind
  public let priority: Int
  public let track: NormalizedTrack

  public init(
    id: TrajectorySourceID,
    displayName: String? = nil,
    kind: TrajectorySourceKind,
    priority: Int = 100,
    track: NormalizedTrack
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.priority = priority
    self.track = track
  }
}

public enum TrajectoryMobility: String, Hashable, Sendable, Codable {
  case ground
  case unknown
}

public struct TrajectorySession: Hashable, Sendable, Codable, Identifiable {
  public let id: String
  public let sourceID: TrajectorySourceID
  public let sourceKind: TrajectorySourceKind
  public let sourcePriority: Int
  public let sourceSegmentID: Int
  public let points: [TrackPoint]
  public let intervals: [TrackInterval]
  public let mobility: TrajectoryMobility

  public init(
    id: String,
    sourceID: TrajectorySourceID,
    sourceKind: TrajectorySourceKind,
    sourcePriority: Int,
    sourceSegmentID: Int,
    points: [TrackPoint],
    intervals: [TrackInterval],
    mobility: TrajectoryMobility = .ground
  ) {
    self.id = id
    self.sourceID = sourceID
    self.sourceKind = sourceKind
    self.sourcePriority = sourcePriority
    self.sourceSegmentID = sourceSegmentID
    self.points = points
    self.intervals = intervals
    self.mobility = mobility
  }

  public var startTimeUTC: Date? { points.first?.timestamp }
  public var endTimeUTC: Date? { points.last?.timestamp }

  public var normalizedTrack: NormalizedTrack {
    NormalizedTrack(
      segments: [
        NormalizedTrackSegment(
          id: sourceSegmentID,
          sourceTrackIndex: points.first?.source.trackIndex ?? 0,
          sourceSegmentIndex: points.first?.source.segmentIndex ?? 0,
          points: points,
          intervals: intervals
        )
      ],
      warnings: []
    )
  }
}

public enum TrajectoryRelationKind: String, Hashable, Sendable, Codable {
  case missingCoverage
  case flightBoundary
  case sourceSegmentBoundary
}

public struct TrajectoryRelation: Hashable, Sendable, Codable, Identifiable {
  public let id: String
  public let sourceID: TrajectorySourceID
  public let leftSessionID: String
  public let rightSessionID: String
  public let kind: TrajectoryRelationKind
  public let durationSeconds: TimeInterval
  public let distanceMeters: Double
  public let impliedSpeedMetersPerSecond: Double?

  public init(
    id: String,
    sourceID: TrajectorySourceID,
    leftSessionID: String,
    rightSessionID: String,
    kind: TrajectoryRelationKind,
    durationSeconds: TimeInterval,
    distanceMeters: Double,
    impliedSpeedMetersPerSecond: Double?
  ) {
    self.id = id
    self.sourceID = sourceID
    self.leftSessionID = leftSessionID
    self.rightSessionID = rightSessionID
    self.kind = kind
    self.durationSeconds = durationSeconds
    self.distanceMeters = distanceMeters
    self.impliedSpeedMetersPerSecond = impliedSpeedMetersPerSecond
  }
}

public struct TrajectoryCorpus: Hashable, Sendable, Codable {
  public let sources: [TrajectoryLogicalSource]
  public let sessions: [TrajectorySession]
  public let relations: [TrajectoryRelation]

  public init(
    sources: [TrajectoryLogicalSource],
    sessions: [TrajectorySession],
    relations: [TrajectoryRelation]
  ) {
    self.sources = sources
    self.sessions = sessions
    self.relations = relations
  }
}

// MARK: - Candidates, provenance, and results

public enum LocationSourceKind: String, Hashable, Sendable, Codable {
  case manualOverride
  case directSensor
  case sameAsset
  case gpxExact
  case gpxInterpolated
  case embeddedFreshFix
  case embeddedTrackFix
  case burstPropagation
  case sequencePropagation
  case stationaryBounded
  case crossCamera
  case activityRegion
}

public enum LocationEvidenceKind: String, Hashable, Sendable, Codable {
  case manualObservation
  case directObservation
  case relatedAssetObservation
  case trajectoryPoint
  case trajectoryInterval
  case embeddedFix
  case temporalNeighbor
  case sequenceNeighbor
  case stationaryBounds
  case crossCameraNeighbor
  case regionPrior
}

public enum LocationGranularity: String, Hashable, Sendable, Codable {
  case exact
  case precise
  case coarse
  case veryCoarse
}

public enum LocationDecisionConfidence: String, Hashable, Sendable, Codable {
  case high
  case medium
  case low
  case manual
}

public struct LocationEvidence: Hashable, Sendable, Codable, Identifiable {
  public let id: String
  public let kind: LocationEvidenceKind
  public let sourceID: String?
  public let assetIDs: [CaptureAssetID]
  public let coordinate: GeoCoordinate?
  public let observedAtUTC: Date?
  public let fixAgeSeconds: TimeInterval?
  public let horizontalAccuracyMeters: Double?
  public let estimatedRadiusMeters: Double?
  public let hopCount: Int
  public let isCircular: Bool
  public let note: String?

  public init(
    id: String,
    kind: LocationEvidenceKind,
    sourceID: String? = nil,
    assetIDs: [CaptureAssetID] = [],
    coordinate: GeoCoordinate? = nil,
    observedAtUTC: Date? = nil,
    fixAgeSeconds: TimeInterval? = nil,
    horizontalAccuracyMeters: Double? = nil,
    estimatedRadiusMeters: Double? = nil,
    hopCount: Int = 0,
    isCircular: Bool = false,
    note: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.sourceID = sourceID
    self.assetIDs = assetIDs
    self.coordinate = coordinate
    self.observedAtUTC = observedAtUTC
    self.fixAgeSeconds = fixAgeSeconds
    self.horizontalAccuracyMeters = horizontalAccuracyMeters
    self.estimatedRadiusMeters = estimatedRadiusMeters
    self.hopCount = hopCount
    self.isCircular = isCircular
    self.note = note
  }
}

public struct LocationCandidate: Hashable, Sendable, Codable, Identifiable {
  public let id: String
  public let assetID: CaptureAssetID
  public let coordinate: GeoCoordinate
  public let elevationMeters: Double?
  public let sourceKind: LocationSourceKind
  public let granularity: LocationGranularity
  public let confidence: LocationDecisionConfidence
  /// A conservative radius inferred from geometry, not sensor accuracy.
  /// `nil` means the engine has no defensible geometric radius estimate.
  public let estimatedRadiusMeters: Double?
  public let requiresConfirmation: Bool
  public let sourcePriority: Int
  public let ruleID: String
  public let evidence: [LocationEvidence]

  public init(
    id: String,
    assetID: CaptureAssetID,
    coordinate: GeoCoordinate,
    elevationMeters: Double? = nil,
    sourceKind: LocationSourceKind,
    granularity: LocationGranularity,
    confidence: LocationDecisionConfidence,
    estimatedRadiusMeters: Double? = nil,
    requiresConfirmation: Bool,
    sourcePriority: Int = 100,
    ruleID: String,
    evidence: [LocationEvidence]
  ) {
    self.id = id
    self.assetID = assetID
    self.coordinate = coordinate
    self.elevationMeters = elevationMeters
    self.sourceKind = sourceKind
    self.granularity = granularity
    self.confidence = confidence
    self.estimatedRadiusMeters = estimatedRadiusMeters
    self.requiresConfirmation = requiresConfirmation
    self.sourcePriority = sourcePriority
    self.ruleID = ruleID
    self.evidence = evidence
  }
}

public enum LocationResolutionStatus: String, Hashable, Sendable, Codable {
  case resolved
  case review
  case conflict
  case unresolved
}

public enum LocationResolutionReason: String, Hashable, Sendable, Codable {
  case selectedHighestPriority
  case comparableStrongCandidatesConflict
  case weakEvidenceNeedsReview
  case noCandidate
}

public struct LocationResolution: Hashable, Sendable, Codable, Identifiable {
  public var id: CaptureAssetID { assetID }

  public let assetID: CaptureAssetID
  public let status: LocationResolutionStatus
  public let selectedCandidate: LocationCandidate?
  public let candidates: [LocationCandidate]
  public let reasons: [LocationResolutionReason]
  public let maximumComparableConflictMeters: Double?
  public let ruleVersion: String

  public init(
    assetID: CaptureAssetID,
    status: LocationResolutionStatus,
    selectedCandidate: LocationCandidate?,
    candidates: [LocationCandidate],
    reasons: [LocationResolutionReason],
    maximumComparableConflictMeters: Double? = nil,
    ruleVersion: String
  ) {
    self.assetID = assetID
    self.status = status
    self.selectedCandidate = selectedCandidate
    self.candidates = candidates
    self.reasons = reasons
    self.maximumComparableConflictMeters = maximumComparableConflictMeters
    self.ruleVersion = ruleVersion
  }
}

// MARK: - Fixed v2 policy

public struct LocationRulePolicy: Hashable, Sendable, Codable {
  public let version: String
  public let directFixMaximumAgeSeconds: TimeInterval
  public let embeddedFreshFixMaximumAgeSeconds: TimeInterval
  public let burstWindowSeconds: TimeInterval
  public let burstMaximumSequenceGap: Int
  public let burstMaximumAnchorDispersionMeters: Double
  public let sequenceWindowSeconds: TimeInterval
  public let sequenceMaximumGap: Int
  public let sequenceMaximumAnchorDispersionMeters: Double
  public let stationaryMaximumSpanSeconds: TimeInterval
  public let stationaryMaximumAnchorDistanceMeters: Double
  public let crossCameraWindowSeconds: TimeInterval
  public let crossCameraMaximumAnchorDispersionMeters: Double
  public let comparableCandidateConflictMeters: Double
  public let trajectorySessionGapSeconds: TimeInterval
  public let flightBoundarySpeedMetersPerSecond: Double

  public init(
    version: String,
    directFixMaximumAgeSeconds: TimeInterval,
    embeddedFreshFixMaximumAgeSeconds: TimeInterval,
    burstWindowSeconds: TimeInterval,
    burstMaximumSequenceGap: Int,
    burstMaximumAnchorDispersionMeters: Double,
    sequenceWindowSeconds: TimeInterval,
    sequenceMaximumGap: Int,
    sequenceMaximumAnchorDispersionMeters: Double,
    stationaryMaximumSpanSeconds: TimeInterval,
    stationaryMaximumAnchorDistanceMeters: Double,
    crossCameraWindowSeconds: TimeInterval,
    crossCameraMaximumAnchorDispersionMeters: Double,
    comparableCandidateConflictMeters: Double,
    trajectorySessionGapSeconds: TimeInterval,
    flightBoundarySpeedMetersPerSecond: Double
  ) {
    self.version = version
    self.directFixMaximumAgeSeconds = directFixMaximumAgeSeconds
    self.embeddedFreshFixMaximumAgeSeconds = embeddedFreshFixMaximumAgeSeconds
    self.burstWindowSeconds = burstWindowSeconds
    self.burstMaximumSequenceGap = burstMaximumSequenceGap
    self.burstMaximumAnchorDispersionMeters = burstMaximumAnchorDispersionMeters
    self.sequenceWindowSeconds = sequenceWindowSeconds
    self.sequenceMaximumGap = sequenceMaximumGap
    self.sequenceMaximumAnchorDispersionMeters = sequenceMaximumAnchorDispersionMeters
    self.stationaryMaximumSpanSeconds = stationaryMaximumSpanSeconds
    self.stationaryMaximumAnchorDistanceMeters = stationaryMaximumAnchorDistanceMeters
    self.crossCameraWindowSeconds = crossCameraWindowSeconds
    self.crossCameraMaximumAnchorDispersionMeters = crossCameraMaximumAnchorDispersionMeters
    self.comparableCandidateConflictMeters = comparableCandidateConflictMeters
    self.trajectorySessionGapSeconds = trajectorySessionGapSeconds
    self.flightBoundarySpeedMetersPerSecond = flightBoundarySpeedMetersPerSecond
  }

  public static let v2 = LocationRulePolicy(
    version: "2.0",
    directFixMaximumAgeSeconds: 60,
    embeddedFreshFixMaximumAgeSeconds: 120,
    burstWindowSeconds: 30,
    burstMaximumSequenceGap: 3,
    burstMaximumAnchorDispersionMeters: 200,
    sequenceWindowSeconds: 300,
    sequenceMaximumGap: 50,
    sequenceMaximumAnchorDispersionMeters: 500,
    stationaryMaximumSpanSeconds: 1_800,
    stationaryMaximumAnchorDistanceMeters: 500,
    crossCameraWindowSeconds: 120,
    crossCameraMaximumAnchorDispersionMeters: 500,
    comparableCandidateConflictMeters: 1_000,
    trajectorySessionGapSeconds: 1_800,
    flightBoundarySpeedMetersPerSecond: 100
  )
}

public struct LocationInferenceInput: Hashable, Sendable, Codable {
  public let assets: [CaptureAsset]
  public let trajectoryCorpus: TrajectoryCorpus
  public let observations: [AssetLocationObservation]
  public let assetRelations: [AssetRelation]
  public let activityRegions: [ActivityRegion]

  public init(
    assets: [CaptureAsset],
    trajectoryCorpus: TrajectoryCorpus = TrajectoryCorpus(
      sources: [], sessions: [], relations: []),
    observations: [AssetLocationObservation] = [],
    assetRelations: [AssetRelation] = [],
    activityRegions: [ActivityRegion] = []
  ) {
    self.assets = assets
    self.trajectoryCorpus = trajectoryCorpus
    self.observations = observations
    self.assetRelations = assetRelations
    self.activityRegions = activityRegions
  }
}

// MARK: - Clock suggestions

public enum ClockReferenceKind: String, Hashable, Sendable, Codable {
  case directGPS
  case synchronizedAsset
  case userMarker
}

public struct ClockReferenceObservation: Hashable, Sendable, Codable, Identifiable {
  public let id: String
  public let assetID: CaptureAssetID
  public let cameraID: CameraID
  public let cameraCaptureTimeUTC: Date
  public let referenceTimeUTC: Date
  public let kind: ClockReferenceKind
  public let referenceAccuracySeconds: TimeInterval?

  public init(
    id: String,
    assetID: CaptureAssetID,
    cameraID: CameraID,
    cameraCaptureTimeUTC: Date,
    referenceTimeUTC: Date,
    kind: ClockReferenceKind,
    referenceAccuracySeconds: TimeInterval? = nil
  ) {
    self.id = id
    self.assetID = assetID
    self.cameraID = cameraID
    self.cameraCaptureTimeUTC = cameraCaptureTimeUTC
    self.referenceTimeUTC = referenceTimeUTC
    self.kind = kind
    self.referenceAccuracySeconds = referenceAccuracySeconds
  }
}

public enum ClockSuggestionConfidence: String, Hashable, Sendable, Codable {
  case high
  case medium
  case low
}

public enum ClockSuggestionMethod: String, Hashable, Sendable, Codable {
  case robustMedian
}

public struct ClockSuggestion: Hashable, Sendable, Codable, Identifiable {
  public var id: CameraID { cameraID }

  public let cameraID: CameraID
  /// Positive means the camera clock is ahead of the reference and should be shifted backwards.
  public let cameraAheadBySeconds: TimeInterval
  public let confidence: ClockSuggestionConfidence
  public let evidenceCount: Int
  public let rejectedOutlierCount: Int
  public let medianAbsoluteResidualSeconds: TimeInterval
  public let method: ClockSuggestionMethod
  public let evidenceIDs: [String]

  public init(
    cameraID: CameraID,
    cameraAheadBySeconds: TimeInterval,
    confidence: ClockSuggestionConfidence,
    evidenceCount: Int,
    rejectedOutlierCount: Int,
    medianAbsoluteResidualSeconds: TimeInterval,
    method: ClockSuggestionMethod,
    evidenceIDs: [String]
  ) {
    self.cameraID = cameraID
    self.cameraAheadBySeconds = cameraAheadBySeconds
    self.confidence = confidence
    self.evidenceCount = evidenceCount
    self.rejectedOutlierCount = rejectedOutlierCount
    self.medianAbsoluteResidualSeconds = medianAbsoluteResidualSeconds
    self.method = method
    self.evidenceIDs = evidenceIDs
  }
}
