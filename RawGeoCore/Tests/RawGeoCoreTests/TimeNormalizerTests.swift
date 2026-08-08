import XCTest
@testable import RawGeoCore

final class TimeNormalizerTests: XCTestCase {
    private let normalizer = TimeNormalizer()

    func testNormalizesIANAZoneAndPositiveCameraDelta() throws {
        let timestamp = PhotoCaptureTimestamp(
            year: 2026, month: 8, day: 8,
            hour: 14, minute: 14, second: 2
        )
        let result = try normalizer.normalize(
            timestamp,
            timeZoneIdentifier: "Asia/Shanghai",
            cameraClockDelta: 120
        )
        XCTAssertEqual(result, isoDate("2026-08-08T06:12:02Z"))
    }

    func testOriginalOffsetTakesPrecedenceOverIANAZone() throws {
        let timestamp = PhotoCaptureTimestamp(
            year: 2026, month: 8, day: 8,
            hour: 14, minute: 14, second: 2,
            originalUTCOffsetSeconds: 8 * 3_600
        )
        let result = try normalizer.normalize(timestamp, timeZoneIdentifier: "Europe/London")
        XCTAssertEqual(result, isoDate("2026-08-08T06:14:02Z"))
    }

    func testRejectsNonexistentDSTTime() {
        let timestamp = PhotoCaptureTimestamp(
            year: 2026, month: 3, day: 8,
            hour: 2, minute: 30, second: 0
        )
        XCTAssertThrowsError(
            try normalizer.normalize(timestamp, timeZoneIdentifier: "America/New_York")
        ) { error in
            XCTAssertEqual(error as? TimeNormalizationError, .nonexistentLocalTime)
        }
    }

    func testRejectsOrResolvesAmbiguousDSTTime() throws {
        let timestamp = PhotoCaptureTimestamp(
            year: 2026, month: 11, day: 1,
            hour: 1, minute: 30, second: 0
        )
        XCTAssertThrowsError(
            try normalizer.normalize(timestamp, timeZoneIdentifier: "America/New_York")
        ) { error in
            guard case .ambiguousLocalTime = error as? TimeNormalizationError else {
                return XCTFail("Expected ambiguous local time, got \(error)")
            }
        }

        let earlier = try normalizer.normalize(
            timestamp,
            timeZoneIdentifier: "America/New_York",
            ambiguousTimeResolution: .earlier
        )
        let later = try normalizer.normalize(
            timestamp,
            timeZoneIdentifier: "America/New_York",
            ambiguousTimeResolution: .later
        )
        XCTAssertEqual(later.timeIntervalSince(earlier), 3_600)
    }

    func testInvalidZoneAndOffset() {
        let timestamp = PhotoCaptureTimestamp(
            year: 2026, month: 8, day: 8,
            hour: 14, minute: 14, second: 2
        )
        XCTAssertThrowsError(
            try normalizer.normalize(timestamp, timeZoneIdentifier: "Not/AZone")
        )

        let invalidOffsetTimestamp = PhotoCaptureTimestamp(
            year: 2026, month: 8, day: 8,
            hour: 14, minute: 14, second: 2,
            originalUTCOffsetSeconds: 70_000
        )
        XCTAssertThrowsError(
            try normalizer.normalize(invalidOffsetTimestamp, timeZoneIdentifier: "Asia/Shanghai")
        )
    }
}
