import Foundation
import XCTest
@testable import RawGeoCore

final class GPXStreamParserTests: XCTestCase {
    func testParsesGPX11DefaultNamespaceAndExtensions() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="StepOfMyWorld" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><trkseg>
            <trkpt lat="23.01716000" lon="113.76747200">
              <ele>18.5</ele><time>2026-08-08T06:36:54.250Z</time>
              <extensions><speed>-1.00</speed><course>0.00</course></extensions>
            </trkpt>
            <trkpt lat="23.01802900" lon="113.76743400">
              <time>2026-08-08T08:21:40Z</time>
              <extensions><hAcc>12.5</hAcc><speed>1.25</speed></extensions>
            </trkpt>
          </trkseg></trk>
        </gpx>
        """
        let document = try GPXStreamParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(document.version, "1.1")
        XCTAssertEqual(document.creator, "StepOfMyWorld")
        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(document.segments[0].points.count, 2)
        XCTAssertEqual(document.segments[0].points[0].elevationMeters, 18.5)
        XCTAssertNil(document.segments[0].points[0].speedMetersPerSecond)
        XCTAssertEqual(document.segments[0].points[1].speedMetersPerSecond, 1.25)
        XCTAssertEqual(document.segments[0].points[1].horizontalAccuracyMeters, 12.5)
        XCTAssertTrue(document.warnings.isEmpty)
    }

    func testParsesPrefixedGPX10AndReportsBadPoints() throws {
        let xml = """
        <g:gpx version="1.0" creator="Legacy" xmlns:g="http://www.topografix.com/GPX/1/0">
          <g:trk><g:trkseg>
            <g:trkpt lat="91" lon="0"><g:time>2026-01-01T00:00:00Z</g:time></g:trkpt>
            <g:trkpt lat="23" lon="113"></g:trkpt>
            <g:trkpt lat="23" lon="113"><g:time>bad-time</g:time></g:trkpt>
            <g:trkpt lat="23" lon="113"><g:time>2026-01-01T00:00:00+08:00</g:time></g:trkpt>
          </g:trkseg></g:trk>
        </g:gpx>
        """
        let document = try GPXStreamParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(document.version, "1.0")
        XCTAssertEqual(document.segments[0].points.count, 1)
        XCTAssertEqual(document.warnings.count, 3)
        XCTAssertEqual(document.segments[0].points[0].source.pointIndex, 3)
    }

    func testWarnsForUnsupportedVersion() throws {
        let xml = "<gpx version=\"2.0\" creator=\"Future\"><trk><trkseg /></trk></gpx>"
        let document = try GPXStreamParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(document.warnings.first, .unsupportedVersion("2.0"))
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(
            try GPXStreamParser().parse(data: Data("<gpx>".utf8))
        )
    }
}
