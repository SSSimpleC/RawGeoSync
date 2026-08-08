import XCTest
@testable import RawGeoCore

final class TrackNormalizerTests: XCTestCase {
    func testClassifiesReliableReviewStayAndGapIntervals() {
        let points = [
            point(0, latitude: 0, longitude: 0, sourceIndex: 0),
            point(300, latitude: 0.009, longitude: 0, sourceIndex: 1),
            point(600, latitude: 0.04, longitude: 0, sourceIndex: 2),
            point(1_800, latitude: 0.0405, longitude: 0, sourceIndex: 3),
            point(24_000, latitude: 0.041, longitude: 0, sourceIndex: 4)
        ]
        let track = normalizedTrack([
            GPXTrackSegment(trackIndex: 0, segmentIndex: 0, points: points)
        ])
        XCTAssertEqual(
            track.segments[0].intervals.map(\.kind),
            [.reliableInterpolation, .reviewInterpolation, .stayCandidate, .gap]
        )
    }

    func testCollapsesCloseDuplicateAndSplitsConflictAndReversal() {
        let points = [
            point(100, latitude: 0, longitude: 0, sourceIndex: 0),
            point(100, latitude: 0.00001, longitude: 0, sourceIndex: 1),
            point(100, latitude: 1, longitude: 1, sourceIndex: 2),
            point(90, latitude: 1.0001, longitude: 1, sourceIndex: 3)
        ]
        let track = normalizedTrack([
            GPXTrackSegment(trackIndex: 0, segmentIndex: 0, points: points)
        ])
        XCTAssertEqual(track.segments.count, 3)
        XCTAssertTrue(track.warnings.contains {
            if case .duplicatePointCollapsed = $0 { return true }
            return false
        })
        XCTAssertTrue(track.warnings.contains {
            if case .conflictingDuplicateTimestamp = $0 { return true }
            return false
        })
        XCTAssertTrue(track.warnings.contains {
            if case .reversedTimestamp = $0 { return true }
            return false
        })
    }

    func testRemovesOnlyIsolatedSpatialSpike() {
        let points = [
            point(0, latitude: 0, longitude: 0, sourceIndex: 0),
            point(60, latitude: 0, longitude: 0.01, sourceIndex: 1),
            point(120, latitude: 0, longitude: 0.0001, sourceIndex: 2)
        ]
        let track = normalizedTrack([
            GPXTrackSegment(trackIndex: 0, segmentIndex: 0, points: points)
        ])
        XCTAssertEqual(track.segments[0].points.map(\.source.pointIndex), [0, 2])
        XCTAssertTrue(track.warnings.contains(.isolatedSpatialSpikeRemoved(points[1].source)))
    }

    func testDoesNotRejectPlausibleFlightSpeed() {
        let points = [
            point(0, latitude: 33.456288, longitude: 116.976114, sourceIndex: 0, speed: 207),
            point(3, latitude: 33.450830, longitude: 116.976108, sourceIndex: 1, speed: 204)
        ]
        let track = normalizedTrack([
            GPXTrackSegment(trackIndex: 0, segmentIndex: 0, points: points)
        ])
        XCTAssertEqual(track.segments[0].intervals[0].kind, .reliableInterpolation)
    }
}
