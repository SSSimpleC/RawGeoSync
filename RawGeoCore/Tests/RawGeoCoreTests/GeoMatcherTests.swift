import XCTest
@testable import RawGeoCore

final class GeoMatcherTests: XCTestCase {
    private let matcher = GeoMatcher()

    func testGreatCircleInterpolationCrossesAntimeridian() {
        let midpoint = GeoMath.interpolate(
            from: GeoCoordinate(latitude: 10, longitude: 179),
            to: GeoCoordinate(latitude: 10, longitude: -179),
            fraction: 0.5
        )
        XCTAssertEqual(midpoint.latitude, 10.00149, accuracy: 0.001)
        XCTAssertEqual(abs(midpoint.longitude), 180, accuracy: 0.0001)
    }

    func testExactAndReliableInterpolation() {
        let segment = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 0,
            points: [
                point(0, latitude: 0, longitude: 0, sourceIndex: 0, elevation: 10, accuracy: 5),
                point(100, latitude: 0, longitude: 0.001, sourceIndex: 1, elevation: 20, accuracy: 8)
            ]
        )
        let track = normalizedTrack([segment])
        let results = matcher.match(
            photos: [
                PhotoCapture(id: "exact", captureTimeUTC: Date(timeIntervalSince1970: 1)),
                PhotoCapture(id: "middle", captureTimeUTC: Date(timeIntervalSince1970: 50))
            ],
            track: track
        )

        XCTAssertEqual(results[0].mode, .exact)
        XCTAssertEqual(results[0].confidence, .reliable)
        XCTAssertEqual(results[0].sensorAccuracy, .known(meters: 5))
        XCTAssertEqual(results[1].mode, .reliableInterpolation)
        XCTAssertEqual(results[1].coordinate!.longitude, 0.0005, accuracy: 0.000001)
        XCTAssertEqual(results[1].elevationMeters!, 15, accuracy: 0.0001)
        XCTAssertEqual(results[1].sensorAccuracy, .known(meters: 8))
    }

    func testReviewInterpolationDoesNotInterpolateElevation() {
        let segment = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 0,
            points: [
                point(0, latitude: 0, longitude: 0, sourceIndex: 0, elevation: 10),
                point(400, latitude: 0, longitude: 0.001, sourceIndex: 1, elevation: 20)
            ]
        )
        let result = matcher.match(
            photos: [PhotoCapture(id: "review", captureTimeUTC: Date(timeIntervalSince1970: 200))],
            track: normalizedTrack([segment])
        )[0]
        XCTAssertEqual(result.mode, .reviewInterpolation)
        XCTAssertEqual(result.confidence, .review)
        XCTAssertTrue(result.requiresConfirmation)
        XCTAssertNil(result.elevationMeters)
    }

    func testStayCandidateUsesPreviousPointAndExposesBothEndpoints() {
        let segment = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 0,
            points: [
                point(0, latitude: 23.017160, longitude: 113.767472, sourceIndex: 0),
                point(6_286, latitude: 23.018029, longitude: 113.767434, sourceIndex: 1)
            ]
        )
        let result = matcher.match(
            photos: [PhotoCapture(id: "stay", captureTimeUTC: Date(timeIntervalSince1970: 3_000))],
            track: normalizedTrack([segment])
        )[0]
        XCTAssertEqual(result.mode, .stayCandidate)
        XCTAssertEqual(result.coordinate, segment.points[0].coordinate)
        XCTAssertEqual(result.candidates[0].endPoint, segment.points[1])
        XCTAssertEqual(result.reasonCodes, [.stationaryGapCandidate])
    }

    func testGapAllowsNearestAt120SecondsButNot121() {
        let segment = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 0,
            points: [
                point(0, latitude: 0, longitude: 0, sourceIndex: 0),
                point(2_000, latitude: 1, longitude: 1, sourceIndex: 1)
            ]
        )
        let track = normalizedTrack([segment])
        let results = matcher.match(
            photos: [
                PhotoCapture(id: "at-boundary", captureTimeUTC: Date(timeIntervalSince1970: 120)),
                PhotoCapture(id: "outside", captureTimeUTC: Date(timeIntervalSince1970: 121))
            ],
            track: track
        )
        XCTAssertEqual(results[0].mode, .nearest)
        XCTAssertEqual(results[0].reasonCodes, [.gapBoundaryNearest])
        XCTAssertEqual(results[1].mode, .unmatched)
    }

    func testOutsideTrackAllowsNearestOnlyInsideTolerance() {
        let segment = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 0,
            points: [point(1_000, latitude: 0, longitude: 0, sourceIndex: 0)]
        )
        let track = normalizedTrack([segment])
        let results = matcher.match(
            photos: [
                PhotoCapture(id: "near", captureTimeUTC: Date(timeIntervalSince1970: 881)),
                PhotoCapture(id: "far", captureTimeUTC: Date(timeIntervalSince1970: 879))
            ],
            track: track
        )
        XCTAssertEqual(results[0].mode, .nearest)
        XCTAssertEqual(results[0].reasonCodes, [.outsideTrackNearest])
        XCTAssertEqual(results[1].mode, .unmatched)
    }

    func testAgreeingTracksDowngradeToReviewAndConflictingTracksAreAmbiguous() {
        let first = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 0,
            points: [
                point(0, latitude: 0, longitude: 0, sourceIndex: 0, segmentIndex: 0),
                point(100, latitude: 0, longitude: 0.001, sourceIndex: 1, segmentIndex: 0)
            ]
        )
        let close = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 1,
            points: [
                point(0, latitude: 0.0001, longitude: 0, sourceIndex: 0, segmentIndex: 1),
                point(100, latitude: 0.0001, longitude: 0.001, sourceIndex: 1, segmentIndex: 1)
            ]
        )
        let far = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 2,
            points: [
                point(0, latitude: 1, longitude: 1, sourceIndex: 0, segmentIndex: 2),
                point(100, latitude: 1, longitude: 1.001, sourceIndex: 1, segmentIndex: 2)
            ]
        )
        let photo = PhotoCapture(id: "multi", captureTimeUTC: Date(timeIntervalSince1970: 50))

        let agreeing = matcher.match(photos: [photo], track: normalizedTrack([first, close]))[0]
        XCTAssertEqual(agreeing.confidence, .review)
        XCTAssertEqual(agreeing.reasonCodes.last, .agreeingTracks)
        XCTAssertTrue(agreeing.requiresConfirmation)

        let conflicting = matcher.match(photos: [photo], track: normalizedTrack([first, far]))[0]
        XCTAssertEqual(conflicting.mode, .ambiguous)
        XCTAssertNil(conflicting.coordinate)
        XCTAssertEqual(conflicting.reasonCodes, [.conflictingTracks])
    }

    func testFileEnumerationOrderAndSameSecondBurstsAreDeterministic() {
        let segment = GPXTrackSegment(
            trackIndex: 0,
            segmentIndex: 0,
            points: [
                point(0, latitude: 0, longitude: 0, sourceIndex: 0),
                point(100, latitude: 0, longitude: 0.001, sourceIndex: 1)
            ]
        )
        let track = normalizedTrack([segment])
        let photos = [
            PhotoCapture(id: "C", captureTimeUTC: Date(timeIntervalSince1970: 50)),
            PhotoCapture(id: "A", captureTimeUTC: Date(timeIntervalSince1970: 50)),
            PhotoCapture(id: "B", captureTimeUTC: Date(timeIntervalSince1970: 50))
        ]
        let results = matcher.match(photos: photos, track: track)
        XCTAssertEqual(results.map(\.photo.id), ["C", "A", "B"])
        XCTAssertEqual(Set(results.compactMap(\.coordinate)).count, 1)
        XCTAssertEqual(
            matcher.match(photos: photos, track: track),
            matcher.match(photos: photos, track: track)
        )
    }

    func testCurrentSampleGoldenClassification() {
        let trackTimes = [
            "2026-08-08T06:13:04Z", "2026-08-08T06:15:05Z",
            "2026-08-08T06:16:39Z", "2026-08-08T06:18:20Z",
            "2026-08-08T06:20:24Z", "2026-08-08T06:25:18Z",
            "2026-08-08T06:27:45Z", "2026-08-08T06:30:04Z",
            "2026-08-08T06:36:54Z", "2026-08-08T08:21:40Z",
            "2026-08-08T08:26:35Z"
        ]
        var trackPoints: [TrackPoint] = []
        for (index, time) in trackTimes.enumerated() {
            let coordinate: GeoCoordinate
            if index == 8 {
                coordinate = GeoCoordinate(latitude: 23.017160, longitude: 113.767472)
            } else if index == 9 {
                coordinate = GeoCoordinate(latitude: 23.018029, longitude: 113.767434)
            } else if index == 10 {
                coordinate = GeoCoordinate(latitude: 23.01840, longitude: 113.76760)
            } else {
                coordinate = GeoCoordinate(latitude: 23.010 + Double(index) * 0.0008, longitude: 113.7675)
            }
            trackPoints.append(
                TrackPoint(
                    timestamp: isoDate(time),
                    coordinate: coordinate,
                    source: TrackPointSource(trackIndex: 0, segmentIndex: 0, pointIndex: index)
                )
            )
        }

        let photoTimes = [
            "06:14:02", "06:14:19", "06:16:15", "06:16:18", "06:17:50",
            "06:19:32", "06:19:54", "06:19:55", "06:19:55", "06:22:27",
            "06:25:03", "06:25:24", "06:25:24", "06:25:25", "06:25:57",
            "06:26:13", "06:27:54", "06:28:02", "06:28:03", "06:28:03",
            "06:28:04", "06:28:06", "06:28:07", "06:39:54", "06:40:01",
            "06:40:23", "07:00:02", "07:00:20", "07:01:04", "07:01:16",
            "07:01:18", "07:02:09", "07:02:24", "07:34:26", "07:35:21",
            "07:35:37", "07:35:50", "07:35:58", "07:37:01", "08:16:22",
            "08:16:35", "08:16:43", "08:20:55", "08:20:57", "08:21:05",
            "08:21:16", "08:21:44", "08:22:13", "08:22:24", "08:22:25",
            "08:22:30", "08:24:44"
        ]
        let photos = photoTimes.enumerated().map { index, time in
            PhotoCapture(
                id: String(format: "DSC_%04d", 386 + index),
                captureTimeUTC: isoDate("2026-08-08T\(time)Z")
            )
        }
        let segment = GPXTrackSegment(trackIndex: 0, segmentIndex: 0, points: trackPoints)
        let results = matcher.match(photos: photos, track: normalizedTrack([segment]))

        XCTAssertEqual(results.filter { $0.confidence == .reliable }.count, 29)
        XCTAssertEqual(results.filter { $0.mode == .stayCandidate }.count, 23)
        XCTAssertEqual(results.filter { $0.confidence == .unmatched }.count, 0)
        XCTAssertEqual(Set(results[23...45].compactMap(\.coordinate)).count, 1)
    }
}
