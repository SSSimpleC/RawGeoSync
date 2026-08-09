import XCTest

@testable import RawGeoCore

final class V2InferenceTests: XCTestCase {
  private let origin = GeoCoordinate(latitude: 22.5, longitude: 114.0)
  private let cameraA = CameraIdentity(id: "camera-a", make: "Nikon", model: "Z5")
  private let cameraB = CameraIdentity(id: "camera-b", make: "Nikon", model: "Z50")
  private let cameraC = CameraIdentity(id: "camera-c", make: "Sony", model: "A6400")

  func testCorpusSeparatesFlightAndMissingCoverageAcrossLogicalSources() {
    let first = point(0, origin, index: 0)
    let flown = point(10, GeoCoordinate(latitude: 24.5, longitude: 114), index: 1)
    let later = point(4_000, GeoCoordinate(latitude: 25.5, longitude: 114), index: 2)
    let segment = NormalizedTrackSegment(
      id: 7,
      sourceTrackIndex: 0,
      sourceSegmentIndex: 0,
      points: [first, flown, later],
      intervals: [
        interval(first, flown, kind: .reliableInterpolation, reason: .shortDenseInterval),
        interval(flown, later, kind: .gap, reason: .longMissingCoverage),
      ]
    )
    let firstSource = TrajectoryLogicalSource(
      id: "annual-gpx",
      kind: .gpx,
      priority: 10,
      track: NormalizedTrack(segments: [segment], warnings: [])
    )
    let secondSource = singlePointSource(id: "camera-fixes", time: 20, coordinate: origin)

    let corpus = TrajectoryCorpusBuilder().build(sources: [secondSource, firstSource])

    XCTAssertEqual(corpus.sources.map(\.id.rawValue), ["annual-gpx", "camera-fixes"])
    XCTAssertEqual(corpus.sessions.count, 4)
    XCTAssertEqual(Set(corpus.relations.map(\.kind)), [.flightBoundary, .missingCoverage])
    XCTAssertTrue(
      corpus.sessions.allSatisfy {
        $0.intervals.allSatisfy { interval in
          interval.impliedSpeedMetersPerSecond
            < LocationRulePolicy.v2.flightBoundarySpeedMetersPerSecond
            && interval.kind != .gap
        }
      })
  }

  func testEmbeddedFixBuilderDeduplicatesAndUsesFixTime() throws {
    let assetID: CaptureAssetID = "nef-1"
    let duplicate = AssetLocationObservation(
      id: "fix-b",
      assetID: assetID,
      coordinate: origin,
      gpsTimestampUTC: date(50),
      kind: .cameraEmbedded
    )
    let first = AssetLocationObservation(
      id: "fix-a",
      assetID: assetID,
      coordinate: origin,
      observedAtUTC: date(500),
      gpsTimestampUTC: date(50),
      kind: .cameraEmbedded
    )
    let second = AssetLocationObservation(
      id: "fix-c",
      assetID: "nef-2",
      coordinate: GeoCoordinate(latitude: 22.5001, longitude: 114),
      observedAtUTC: date(800),
      gpsTimestampUTC: date(80),
      kind: .cameraEmbedded
    )

    let source = try XCTUnwrap(
      EmbeddedFixTrajectoryBuilder().makeSource(
        id: "z5-fixes",
        observations: [second, duplicate, first]
      )
    )
    let points = try XCTUnwrap(source.track.segments.first).points
    XCTAssertEqual(points.count, 2)
    XCTAssertEqual(points.map(\.timestamp), [date(50), date(80)])
  }

  func testFreshEmbeddedFixAcceptedButStaleFixIsOnlyTrackMaterial() {
    let freshAsset = asset("fresh", time: 100)
    let staleAsset = asset("stale", time: 500)
    let observations = [
      AssetLocationObservation(
        id: "fresh-fix",
        assetID: freshAsset.id,
        coordinate: origin,
        gpsTimestampUTC: date(40),
        kind: .cameraEmbedded
      ),
      AssetLocationObservation(
        id: "stale-fix",
        assetID: staleAsset.id,
        coordinate: origin,
        gpsTimestampUTC: date(40),
        kind: .cameraEmbedded
      ),
    ]

    let results = DeterministicLocationEngine().resolve(
      LocationInferenceInput(assets: [staleAsset, freshAsset], observations: observations)
    )
    XCTAssertEqual(
      results.first(where: { $0.id == freshAsset.id })?.selectedCandidate?.sourceKind,
      .embeddedFreshFix)
    XCTAssertEqual(results.first(where: { $0.id == staleAsset.id })?.status, .unresolved)
  }

  func testSensorAccuracyRemainsSourceDataAndNoRadiusIsInvented() throws {
    let photo = asset("iphone", time: 10, camera: cameraA)
    let observation = AssetLocationObservation(
      id: "gps",
      assetID: photo.id,
      coordinate: origin,
      gpsTimestampUTC: photo.captureTimeUTC,
      horizontalAccuracyMeters: 18,
      kind: .directSensor
    )
    let result = try XCTUnwrap(
      DeterministicLocationEngine().resolve(
        LocationInferenceInput(assets: [photo], observations: [observation])
      ).first
    )
    let selected = try XCTUnwrap(result.selectedCandidate)
    XCTAssertNil(selected.estimatedRadiusMeters)
    XCTAssertEqual(selected.evidence.first?.horizontalAccuracyMeters, 18)
    XCTAssertNil(selected.evidence.first?.estimatedRadiusMeters)
  }

  func testBurstAndStationaryFallbacksAreSingleHop() throws {
    let activity: ActivityID = "day"
    let anchor = asset("anchor", time: 0, camera: cameraA, activity: activity, sequence: 10)
    let burst = asset("burst", time: 20, camera: cameraA, activity: activity, sequence: 11)
    let before = asset("before", time: 1_000, camera: cameraA, activity: activity, sequence: 100)
    let middle = asset("middle", time: 1_600, camera: cameraA, activity: activity, sequence: 150)
    let after = asset("after", time: 2_200, camera: cameraA, activity: activity, sequence: 200)
    let near = GeoCoordinate(latitude: 22.5003, longitude: 114)
    let observations = [
      directObservation("anchor-gps", asset: anchor, coordinate: origin),
      directObservation("before-gps", asset: before, coordinate: origin),
      directObservation("after-gps", asset: after, coordinate: near),
    ]

    let results = DeterministicLocationEngine().resolve(
      LocationInferenceInput(
        assets: [after, middle, burst, before, anchor],
        observations: observations
      )
    )
    let burstResult = try XCTUnwrap(results.first(where: { $0.id == burst.id }))
    XCTAssertEqual(burstResult.selectedCandidate?.sourceKind, .burstPropagation)
    XCTAssertEqual(burstResult.status, .review)
    XCTAssertEqual(burstResult.selectedCandidate?.evidence.first?.hopCount, 1)
    let middleResult = try XCTUnwrap(results.first(where: { $0.id == middle.id }))
    XCTAssertEqual(middleResult.selectedCandidate?.sourceKind, .stationaryBounded)
    XCTAssertEqual(middleResult.status, .review)
    XCTAssertEqual(
      middleResult.selectedCandidate?.evidence.count(where: { $0.hopCount == 1 }),
      2
    )
    XCTAssertTrue(
      middleResult.selectedCandidate?.evidence.contains(where: { $0.hopCount == 0 }) == true
    )
    XCTAssertNotNil(middleResult.selectedCandidate?.estimatedRadiusMeters)
  }

  func testPropagationDoesNotCrossActivityOrDisagreeingPlaces() throws {
    let anchor = asset("anchor", time: 0, camera: cameraA, activity: "one", sequence: 1)
    let otherActivity = asset("other", time: 10, camera: cameraA, activity: "two", sequence: 2)
    let target = asset("target", time: 20, camera: cameraB, activity: "one", sequence: 3)
    let farAnchor = asset("far", time: 25, camera: cameraC, activity: "one", sequence: 4)
    let far = GeoCoordinate(latitude: 31.2, longitude: 121.5)
    let results = DeterministicLocationEngine().resolve(
      LocationInferenceInput(
        assets: [target, otherActivity, anchor, farAnchor],
        observations: [
          directObservation("near", asset: anchor, coordinate: origin),
          directObservation("far", asset: farAnchor, coordinate: far),
        ]
      )
    )

    XCTAssertEqual(results.first(where: { $0.id == otherActivity.id })?.status, .unresolved)
    let targetResult = try XCTUnwrap(results.first(where: { $0.id == target.id }))
    XCTAssertFalse(targetResult.candidates.contains { $0.sourceKind == .crossCamera })
  }

  func testCrossCameraStrongAnchorAndRegionFallback() throws {
    let anchor = asset("a", time: 0, camera: cameraA, activity: "day")
    let target = asset("b", time: 60, camera: cameraB, activity: "day")
    let regionOnly = asset("c", time: 5_000, camera: cameraB, activity: "region")
    let results = DeterministicLocationEngine().resolve(
      LocationInferenceInput(
        assets: [regionOnly, target, anchor],
        observations: [directObservation("gps", asset: anchor, coordinate: origin)],
        activityRegions: [
          ActivityRegion(
            id: "dongguan",
            activityID: "region",
            coordinate: origin,
            radiusMeters: 15_000,
            source: .placeName
          )
        ]
      )
    )
    XCTAssertEqual(
      results.first(where: { $0.id == target.id })?.selectedCandidate?.sourceKind,
      .crossCamera)
    XCTAssertEqual(results.first(where: { $0.id == target.id })?.status, .review)
    XCTAssertEqual(
      results.first(where: { $0.id == regionOnly.id })?.selectedCandidate?.sourceKind,
      .activityRegion)
    XCTAssertEqual(results.first(where: { $0.id == regionOnly.id })?.status, .review)
  }

  func testCrossCameraEvidenceUsesBoundedRepresentatives() throws {
    let target = asset("target", time: 60, camera: cameraA, activity: "day")
    let anchors = (0..<10).map { index in
      asset(
        "anchor-\(index)",
        time: Double(50 + index),
        camera: CameraIdentity(id: CameraID(rawValue: "camera-\(index + 10)")),
        activity: "day"
      )
    }
    let observations = anchors.enumerated().map { index, anchor in
      directObservation(
        "gps-\(index)",
        asset: anchor,
        coordinate: GeoCoordinate(
          latitude: origin.latitude + Double(index) * 0.000_001,
          longitude: origin.longitude
        )
      )
    }

    let result = try XCTUnwrap(
      DeterministicLocationEngine().resolve(
        LocationInferenceInput(assets: [target] + anchors, observations: observations)
      ).first(where: { $0.id == target.id })
    )

    XCTAssertEqual(result.selectedCandidate?.sourceKind, .crossCamera)
    XCTAssertLessThanOrEqual(result.selectedCandidate?.evidence.count ?? .max, 6)
  }

  func testComparableStrongTracksConflictButWeakRegionCannotOverrideDirectSensor() throws {
    let photo = asset("photo", time: 100, camera: cameraA, activity: "day")
    let shanghai = GeoCoordinate(latitude: 31.2, longitude: 121.5)
    let sourceOne = singlePointSource(id: "gpx-a", time: 100, coordinate: origin)
    let sourceTwo = singlePointSource(id: "gpx-b", time: 100, coordinate: shanghai)
    let corpus = TrajectoryCorpusBuilder().build(sources: [sourceTwo, sourceOne])

    let conflict = try XCTUnwrap(
      DeterministicLocationEngine().resolve(
        LocationInferenceInput(assets: [photo], trajectoryCorpus: corpus)
      ).first
    )
    XCTAssertEqual(conflict.status, .conflict)
    XCTAssertNil(conflict.selectedCandidate)
    XCTAssertGreaterThan(conflict.maximumComparableConflictMeters ?? 0, 1_000)

    let direct = directObservation("direct", asset: photo, coordinate: origin)
    let resolved = try XCTUnwrap(
      DeterministicLocationEngine().resolve(
        LocationInferenceInput(
          assets: [photo],
          observations: [direct],
          activityRegions: [
            ActivityRegion(
              id: "weak-shanghai",
              activityID: "day",
              coordinate: shanghai,
              radiusMeters: 10_000,
              source: .placeName
            )
          ]
        )
      ).first
    )
    XCTAssertEqual(resolved.status, .resolved)
    XCTAssertEqual(resolved.selectedCandidate?.sourceKind, .directSensor)
  }

  func testCircularSameAssetEvidenceDoesNotOverrideIndependentTrack() throws {
    let photo = asset("photo", time: 100, camera: cameraA, activity: "day")
    let circular = AssetLocationObservation(
      id: "generated-sidecar",
      assetID: photo.id,
      coordinate: GeoCoordinate(latitude: 31.2, longitude: 121.5),
      observedAtUTC: photo.captureTimeUTC,
      kind: .sidecar,
      isCircular: true
    )
    let source = singlePointSource(id: "independent-gpx", time: 100, coordinate: origin)
    let corpus = TrajectoryCorpusBuilder().build(sources: [source])

    let result = try XCTUnwrap(
      DeterministicLocationEngine().resolve(
        LocationInferenceInput(
          assets: [photo],
          trajectoryCorpus: corpus,
          observations: [circular]
        )
      ).first
    )

    XCTAssertEqual(result.selectedCandidate?.sourceKind, .gpxExact)
    XCTAssertTrue(result.candidates.contains(where: { $0.sourceKind == .sameAsset }))
  }

  func testResolutionIsDeterministicAcrossInputOrdering() {
    let photo = asset("photo", time: 100, camera: cameraA, activity: "day")
    let observations = [
      directObservation("z", asset: photo, coordinate: origin),
      directObservation("a", asset: photo, coordinate: origin),
    ]
    let engine = DeterministicLocationEngine()
    let forward = engine.resolve(
      LocationInferenceInput(assets: [photo], observations: observations)
    )
    let reversed = engine.resolve(
      LocationInferenceInput(assets: [photo], observations: observations.reversed())
    )
    XCTAssertEqual(forward, reversed)
  }

  func testActivityRegionsOnlyApplyInsideTheirPhotoSession() throws {
    let early = asset("early", time: 100, camera: cameraA, activity: "travel-day")
    let late = asset("late", time: 300, camera: cameraA, activity: "travel-day")
    let lateCoordinate = GeoCoordinate(latitude: 31.2, longitude: 121.5)
    let regions = [
      ActivityRegion(
        id: "early-region",
        activityID: "travel-day",
        coordinate: origin,
        radiusMeters: 10_000,
        source: .learned,
        activeFromUTC: date(50),
        activeToUTC: date(150)
      ),
      ActivityRegion(
        id: "late-region",
        activityID: "travel-day",
        coordinate: lateCoordinate,
        radiusMeters: 10_000,
        source: .learned,
        activeFromUTC: date(250),
        activeToUTC: date(350)
      ),
    ]

    let results = DeterministicLocationEngine().resolve(
      LocationInferenceInput(assets: [late, early], activityRegions: regions)
    )
    let byAsset = Dictionary(uniqueKeysWithValues: results.map { ($0.assetID, $0) })
    XCTAssertEqual(try XCTUnwrap(byAsset[early.id]?.selectedCandidate?.coordinate), origin)
    XCTAssertEqual(try XCTUnwrap(byAsset[late.id]?.selectedCandidate?.coordinate), lateCoordinate)
    XCTAssertEqual(byAsset[early.id]?.candidates.count, 1)
    XCTAssertEqual(byAsset[late.id]?.candidates.count, 1)
  }

  func testClockSuggestionUsesRobustMedianAndRejectsOutlier() throws {
    var observations = (0..<10).map { index in
      ClockReferenceObservation(
        id: "clock-\(index)",
        assetID: CaptureAssetID(rawValue: "asset-\(index)"),
        cameraID: "camera-a",
        cameraCaptureTimeUTC: date(Double(index * 100 + 5)),
        referenceTimeUTC: date(Double(index * 100)),
        kind: .directGPS,
        referenceAccuracySeconds: 1
      )
    }
    observations.append(
      ClockReferenceObservation(
        id: "outlier",
        assetID: "outlier",
        cameraID: "camera-a",
        cameraCaptureTimeUTC: date(2_000),
        referenceTimeUTC: date(1_000),
        kind: .directGPS,
        referenceAccuracySeconds: 1
      )
    )

    let suggestion = try XCTUnwrap(ClockSuggestionEngine().suggest(from: observations).first)
    XCTAssertEqual(suggestion.cameraAheadBySeconds, 5, accuracy: 0.001)
    XCTAssertEqual(suggestion.confidence, .high)
    XCTAssertEqual(suggestion.evidenceCount, 10)
    XCTAssertEqual(suggestion.rejectedOutlierCount, 1)
  }

  private func asset(
    _ id: String,
    time: Double,
    camera: CameraIdentity? = nil,
    activity: ActivityID? = nil,
    sequence: Int? = nil
  ) -> CaptureAsset {
    CaptureAsset(
      id: CaptureAssetID(rawValue: id),
      relativePath: id,
      activityID: activity,
      camera: camera,
      captureTimeUTC: date(time),
      sequenceNumber: sequence
    )
  }

  private func directObservation(
    _ id: String,
    asset: CaptureAsset,
    coordinate: GeoCoordinate
  ) -> AssetLocationObservation {
    AssetLocationObservation(
      id: id,
      assetID: asset.id,
      coordinate: coordinate,
      gpsTimestampUTC: asset.captureTimeUTC,
      horizontalAccuracyMeters: 10,
      kind: .directSensor
    )
  }

  private func singlePointSource(
    id: TrajectorySourceID,
    time: Double,
    coordinate: GeoCoordinate
  ) -> TrajectoryLogicalSource {
    let point = point(time, coordinate, index: 0)
    let segment = NormalizedTrackSegment(
      id: 0,
      sourceTrackIndex: 0,
      sourceSegmentIndex: 0,
      points: [point],
      intervals: []
    )
    return TrajectoryLogicalSource(
      id: id,
      kind: id.rawValue.contains("fix") ? .embeddedCameraFixes : .gpx,
      priority: id.rawValue == "annual-gpx" ? 10 : 100,
      track: NormalizedTrack(segments: [segment], warnings: [])
    )
  }

  private func point(
    _ time: Double,
    _ coordinate: GeoCoordinate,
    index: Int
  ) -> TrackPoint {
    TrackPoint(
      timestamp: date(time),
      coordinate: coordinate,
      source: TrackPointSource(trackIndex: 0, segmentIndex: 0, pointIndex: index)
    )
  }

  private func interval(
    _ start: TrackPoint,
    _ end: TrackPoint,
    kind: TrackIntervalKind,
    reason: TrackIntervalReason
  ) -> TrackInterval {
    let duration = end.timestamp.timeIntervalSince(start.timestamp)
    let distance = GeoMath.distance(from: start.coordinate, to: end.coordinate)
    return TrackInterval(
      start: start,
      end: end,
      durationSeconds: duration,
      distanceMeters: distance,
      impliedSpeedMetersPerSecond: distance / duration,
      kind: kind,
      reason: reason
    )
  }

  private func date(_ seconds: Double) -> Date {
    Date(timeIntervalSince1970: seconds)
  }
}
