import Foundation

public struct GeoCoordinate: Hashable, Sendable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }
}

public struct TrackPointSource: Hashable, Sendable, Codable {
    public let trackIndex: Int
    public let segmentIndex: Int
    public let pointIndex: Int

    public init(trackIndex: Int, segmentIndex: Int, pointIndex: Int) {
        self.trackIndex = trackIndex
        self.segmentIndex = segmentIndex
        self.pointIndex = pointIndex
    }
}

public struct TrackPoint: Hashable, Sendable, Codable {
    public let timestamp: Date
    public let coordinate: GeoCoordinate
    public let elevationMeters: Double?
    public let horizontalAccuracyMeters: Double?
    public let speedMetersPerSecond: Double?
    public let courseDegrees: Double?
    public let source: TrackPointSource

    public init(
        timestamp: Date,
        coordinate: GeoCoordinate,
        elevationMeters: Double? = nil,
        horizontalAccuracyMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil,
        source: TrackPointSource
    ) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.elevationMeters = elevationMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
        self.source = source
    }
}

public struct GPXTrackSegment: Hashable, Sendable, Codable {
    public let trackIndex: Int
    public let segmentIndex: Int
    public let points: [TrackPoint]

    public init(trackIndex: Int, segmentIndex: Int, points: [TrackPoint]) {
        self.trackIndex = trackIndex
        self.segmentIndex = segmentIndex
        self.points = points
    }
}

public enum GPXWarning: Hashable, Sendable, Codable {
    case unsupportedVersion(String)
    case pointMissingTimestamp(trackIndex: Int, segmentIndex: Int, pointIndex: Int)
    case pointHasInvalidCoordinate(trackIndex: Int, segmentIndex: Int, pointIndex: Int)
    case pointHasInvalidTimestamp(trackIndex: Int, segmentIndex: Int, pointIndex: Int, value: String)
    case pointOutsideSegment(pointIndex: Int)
}

public struct GPXDocument: Hashable, Sendable, Codable {
    public let version: String?
    public let creator: String?
    public let segments: [GPXTrackSegment]
    public let warnings: [GPXWarning]

    public init(
        version: String?,
        creator: String?,
        segments: [GPXTrackSegment],
        warnings: [GPXWarning] = []
    ) {
        self.version = version
        self.creator = creator
        self.segments = segments
        self.warnings = warnings
    }
}

public enum TrackIntervalKind: String, Hashable, Sendable, Codable {
    case reliableInterpolation
    case reviewInterpolation
    case stayCandidate
    case gap
}

public enum TrackIntervalReason: String, Hashable, Sendable, Codable {
    case shortDenseInterval
    case sparseOrLongDistanceInterval
    case longSmallDisplacement
    case longMissingCoverage
    case excessiveImpliedSpeed
}

public struct TrackInterval: Hashable, Sendable, Codable {
    public let start: TrackPoint
    public let end: TrackPoint
    public let durationSeconds: TimeInterval
    public let distanceMeters: Double
    public let impliedSpeedMetersPerSecond: Double
    public let kind: TrackIntervalKind
    public let reason: TrackIntervalReason

    public init(
        start: TrackPoint,
        end: TrackPoint,
        durationSeconds: TimeInterval,
        distanceMeters: Double,
        impliedSpeedMetersPerSecond: Double,
        kind: TrackIntervalKind,
        reason: TrackIntervalReason
    ) {
        self.start = start
        self.end = end
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.impliedSpeedMetersPerSecond = impliedSpeedMetersPerSecond
        self.kind = kind
        self.reason = reason
    }
}

public struct NormalizedTrackSegment: Hashable, Sendable, Codable {
    public let id: Int
    public let sourceTrackIndex: Int
    public let sourceSegmentIndex: Int
    public let points: [TrackPoint]
    public let intervals: [TrackInterval]

    public init(
        id: Int,
        sourceTrackIndex: Int,
        sourceSegmentIndex: Int,
        points: [TrackPoint],
        intervals: [TrackInterval]
    ) {
        self.id = id
        self.sourceTrackIndex = sourceTrackIndex
        self.sourceSegmentIndex = sourceSegmentIndex
        self.points = points
        self.intervals = intervals
    }
}

public enum TrackNormalizationWarning: Hashable, Sendable, Codable {
    case invalidPoint(TrackPointSource)
    case duplicatePointCollapsed(kept: TrackPointSource, removed: TrackPointSource)
    case conflictingDuplicateTimestamp(first: TrackPointSource, second: TrackPointSource)
    case reversedTimestamp(previous: TrackPointSource, next: TrackPointSource)
    case isolatedSpatialSpikeRemoved(TrackPointSource)
}

public struct NormalizedTrack: Hashable, Sendable, Codable {
    public let segments: [NormalizedTrackSegment]
    public let warnings: [TrackNormalizationWarning]

    public init(segments: [NormalizedTrackSegment], warnings: [TrackNormalizationWarning]) {
        self.segments = segments
        self.warnings = warnings
    }
}

public struct PhotoCaptureTimestamp: Hashable, Sendable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int
    public let nanosecond: Int
    public let originalUTCOffsetSeconds: Int?

    public init(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        nanosecond: Int = 0,
        originalUTCOffsetSeconds: Int? = nil
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond
        self.originalUTCOffsetSeconds = originalUTCOffsetSeconds
    }
}

public struct PhotoCapture: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let captureTimeUTC: Date

    public init(id: String, captureTimeUTC: Date) {
        self.id = id
        self.captureTimeUTC = captureTimeUTC
    }
}

public enum MatchMode: String, Hashable, Sendable, Codable {
    case exact
    case reliableInterpolation
    case reviewInterpolation
    case stayCandidate
    case nearest
    case ambiguous
    case unmatched
}

public enum MatchConfidence: String, Hashable, Sendable, Codable {
    case reliable
    case review
    case unmatched
}

public enum SensorAccuracy: Hashable, Sendable, Codable {
    case known(meters: Double)
    case unknown
}

public enum MatchReasonCode: String, Hashable, Sendable, Codable {
    case exactTrackPoint
    case shortBracketingInterval
    case sparseBracketingInterval
    case stationaryGapCandidate
    case gapBoundaryNearest
    case outsideTrackNearest
    case noTrackCoverage
    case agreeingTracks
    case conflictingTracks
}

public struct MatchCandidate: Hashable, Sendable, Codable {
    public let segmentID: Int
    public let mode: MatchMode
    public let confidence: MatchConfidence
    public let coordinate: GeoCoordinate
    public let elevationMeters: Double?
    public let startPoint: TrackPoint
    public let endPoint: TrackPoint?
    public let reason: MatchReasonCode

    public init(
        segmentID: Int,
        mode: MatchMode,
        confidence: MatchConfidence,
        coordinate: GeoCoordinate,
        elevationMeters: Double?,
        startPoint: TrackPoint,
        endPoint: TrackPoint?,
        reason: MatchReasonCode
    ) {
        self.segmentID = segmentID
        self.mode = mode
        self.confidence = confidence
        self.coordinate = coordinate
        self.elevationMeters = elevationMeters
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.reason = reason
    }
}

public struct PhotoMatchResult: Hashable, Sendable, Codable {
    public let photo: PhotoCapture
    public let mode: MatchMode
    public let confidence: MatchConfidence
    public let coordinate: GeoCoordinate?
    public let elevationMeters: Double?
    public let sensorAccuracy: SensorAccuracy
    public let requiresConfirmation: Bool
    public let reasonCodes: [MatchReasonCode]
    public let candidates: [MatchCandidate]

    public init(
        photo: PhotoCapture,
        mode: MatchMode,
        confidence: MatchConfidence,
        coordinate: GeoCoordinate?,
        elevationMeters: Double?,
        sensorAccuracy: SensorAccuracy,
        requiresConfirmation: Bool,
        reasonCodes: [MatchReasonCode],
        candidates: [MatchCandidate]
    ) {
        self.photo = photo
        self.mode = mode
        self.confidence = confidence
        self.coordinate = coordinate
        self.elevationMeters = elevationMeters
        self.sensorAccuracy = sensorAccuracy
        self.requiresConfirmation = requiresConfirmation
        self.reasonCodes = reasonCodes
        self.candidates = candidates
    }
}
