import Foundation

/// Additive v2 inference pipeline. It never mutates assets and always returns
/// candidates and provenance in deterministic order.
public struct DeterministicLocationEngine: Sendable {
  public let policy: LocationRulePolicy
  public let matcherConfiguration: GeoMatcherConfiguration

  public init(
    policy: LocationRulePolicy = .v2,
    matcherConfiguration: GeoMatcherConfiguration = .default
  ) {
    self.policy = policy
    self.matcherConfiguration = matcherConfiguration
  }

  public func resolve(_ input: LocationInferenceInput) -> [LocationResolution] {
    let assets = input.assets.sorted(by: assetOrder)
    let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    let observationsByAsset = Dictionary(grouping: input.observations, by: \.assetID)
    let regionsByActivity = Dictionary(grouping: input.activityRegions, by: \.activityID)
    var candidatesByAsset: [CaptureAssetID: [LocationCandidate]] = [:]

    for asset in assets {
      candidatesByAsset[asset.id, default: []].append(
        contentsOf: observationCandidates(
          for: asset,
          observations: observationsByAsset[asset.id, default: []]
        )
      )
    }
    addRelatedAssetCandidates(
      relations: input.assetRelations,
      observations: input.observations,
      assets: assetByID,
      candidatesByAsset: &candidatesByAsset
    )

    for asset in assets {
      candidatesByAsset[asset.id, default: []].append(
        contentsOf: trajectoryCandidates(for: asset, corpus: input.trajectoryCorpus)
      )
    }

    let primaryAnchors = makePrimaryAnchors(
      assets: assets,
      candidatesByAsset: candidatesByAsset
    )
    let anchorIndex = makeAnchorIndex(primaryAnchors)
    for asset in assets {
      let activityAnchors = asset.activityID.flatMap { anchorIndex.byActivity[$0] } ?? []
      let streamAnchors = anchorStreamKey(for: asset).flatMap { anchorIndex.byStream[$0] } ?? []
      candidatesByAsset[asset.id, default: []].append(
        contentsOf: propagationCandidates(
          for: asset,
          sameStreamAnchors: streamAnchors,
          activityAnchors: activityAnchors
        )
      )
      candidatesByAsset[asset.id, default: []].append(
        contentsOf: regionCandidates(
          for: asset,
          regions: asset.activityID.flatMap { regionsByActivity[$0] } ?? []
        )
      )
    }

    return assets.map { asset in
      resolve(
        asset: asset,
        candidates: deduplicated(candidatesByAsset[asset.id, default: []])
      )
    }
  }

  // MARK: Direct and related observations

  private func observationCandidates(
    for asset: CaptureAsset,
    observations: [AssetLocationObservation]
  ) -> [LocationCandidate] {
    observations.sorted { $0.id < $1.id }.compactMap { observation in
      guard observation.coordinate.isValid else { return nil }
      let age = fixAge(for: observation, asset: asset)
      let sourceKind: LocationSourceKind
      let evidenceKind: LocationEvidenceKind
      let ruleID: String
      let requiresConfirmation: Bool

      switch observation.kind {
      case .manual:
        sourceKind = .manualOverride
        evidenceKind = .manualObservation
        ruleID = "v2.manual-override"
        requiresConfirmation = false
      case .directSensor:
        if let age, age > policy.directFixMaximumAgeSeconds { return nil }
        sourceKind = .directSensor
        evidenceKind = .directObservation
        ruleID = "v2.direct-sensor-fresh"
        requiresConfirmation = (observation.horizontalAccuracyMeters ?? 0) > 500
      case .cameraEmbedded:
        guard let age, age <= policy.embeddedFreshFixMaximumAgeSeconds else { return nil }
        sourceKind = .embeddedFreshFix
        evidenceKind = .embeddedFix
        ruleID = "v2.embedded-fix-fresh"
        requiresConfirmation = (observation.horizontalAccuracyMeters ?? 0) > 500
      case .sidecar, .renderedDerivative:
        sourceKind = .sameAsset
        evidenceKind = .relatedAssetObservation
        ruleID = "v2.same-asset-observation"
        requiresConfirmation = observation.isCircular
      }

      let granularity = spatialGranularity(
        horizontalAccuracyMeters: observation.horizontalAccuracyMeters
      )
      let confidence: LocationDecisionConfidence
      if sourceKind == .manualOverride {
        confidence = .manual
      } else if requiresConfirmation || granularity == .veryCoarse {
        confidence = .low
      } else {
        confidence = .high
      }
      let evidence = LocationEvidence(
        id: "observation:\(observation.id)",
        kind: evidenceKind,
        sourceID: observation.id,
        assetIDs: [asset.id],
        coordinate: observation.coordinate,
        observedAtUTC: observation.gpsTimestampUTC ?? observation.observedAtUTC,
        fixAgeSeconds: age,
        horizontalAccuracyMeters: observation.horizontalAccuracyMeters,
        estimatedRadiusMeters: nil,
        hopCount: 0,
        isCircular: observation.isCircular
      )
      return candidate(
        asset: asset,
        coordinate: observation.coordinate,
        elevationMeters: observation.elevationMeters,
        sourceKind: sourceKind,
        granularity: granularity,
        confidence: confidence,
        radius: nil,
        requiresConfirmation: requiresConfirmation,
        ruleID: ruleID,
        evidence: [evidence]
      )
    }
  }

  private func addRelatedAssetCandidates(
    relations: [AssetRelation],
    observations: [AssetLocationObservation],
    assets: [CaptureAssetID: CaptureAsset],
    candidatesByAsset: inout [CaptureAssetID: [LocationCandidate]]
  ) {
    let observationsByAsset = Dictionary(grouping: observations, by: \.assetID)
    for relation in relations.sorted(by: { $0.id < $1.id }) {
      let pairs: [(source: CaptureAssetID, target: CaptureAssetID)]
      if relation.kind == .sameAsset {
        pairs = [
          (relation.sourceAssetID, relation.targetAssetID),
          (relation.targetAssetID, relation.sourceAssetID),
        ]
      } else {
        pairs = [(relation.sourceAssetID, relation.targetAssetID)]
      }

      for pair in pairs {
        guard let target = assets[pair.target] else { continue }
        for observation in observationsByAsset[pair.source, default: []].sorted(by: {
          $0.id < $1.id
        }) where observation.coordinate.isValid {
          let granularity = spatialGranularity(
            horizontalAccuracyMeters: observation.horizontalAccuracyMeters
          )
          let evidence = LocationEvidence(
            id: "relation:\(relation.id):\(observation.id)",
            kind: .relatedAssetObservation,
            sourceID: relation.id,
            assetIDs: [pair.source, pair.target],
            coordinate: observation.coordinate,
            observedAtUTC: observation.gpsTimestampUTC ?? observation.observedAtUTC,
            horizontalAccuracyMeters: observation.horizontalAccuracyMeters,
            estimatedRadiusMeters: nil,
            hopCount: 1,
            isCircular: observation.isCircular,
            note: relation.kind.rawValue
          )
          candidatesByAsset[target.id, default: []].append(
            candidate(
              asset: target,
              coordinate: observation.coordinate,
              elevationMeters: observation.elevationMeters,
              sourceKind: .sameAsset,
              granularity: granularity,
              confidence: observation.isCircular ? .low : .high,
              radius: nil,
              requiresConfirmation: observation.isCircular,
              ruleID: "v2.same-asset-relation",
              evidence: [evidence]
            )
          )
        }
      }
    }
  }

  // MARK: Independent trajectory sources

  private func trajectoryCandidates(
    for asset: CaptureAsset,
    corpus: TrajectoryCorpus
  ) -> [LocationCandidate] {
    let photo = PhotoCapture(id: asset.id.rawValue, captureTimeUTC: asset.captureTimeUTC)
    let matcher = GeoMatcher(configuration: matcherConfiguration)
    var result: [LocationCandidate] = []

    // TrajectoryCorpusBuilder 已经保证 session 顺序稳定。逐张照片再次排序会在
    // 大型年度轨迹上制造大量短命数组，显著放大批量推断的时间和内存开销。
    for session in corpus.sessions {
      guard let startTime = session.startTimeUTC, let endTime = session.endTimeUTC else {
        continue
      }
      let tolerance = matcherConfiguration.nearestToleranceSeconds
      guard asset.captureTimeUTC >= startTime.addingTimeInterval(-tolerance),
        asset.captureTimeUTC <= endTime.addingTimeInterval(tolerance)
      else { continue }
      guard let legacy = matcher.match(photos: [photo], track: session.normalizedTrack).first,
        let coordinate = legacy.coordinate,
        let legacyCandidate = legacy.candidates.first
      else {
        continue
      }

      let isEmbedded = session.sourceKind == .embeddedCameraFixes
      let sourceKind: LocationSourceKind
      let evidenceKind: LocationEvidenceKind
      let granularity: LocationGranularity
      let confidence: LocationDecisionConfidence
      let radius: Double?
      let requiresConfirmation: Bool

      switch legacy.mode {
      case .exact:
        sourceKind = isEmbedded ? .embeddedTrackFix : .gpxExact
        evidenceKind = isEmbedded ? .embeddedFix : .trajectoryPoint
        granularity = .precise
        confidence = .high
        radius = nil
        requiresConfirmation = false
      case .reliableInterpolation:
        sourceKind = isEmbedded ? .embeddedTrackFix : .gpxInterpolated
        evidenceKind = .trajectoryInterval
        granularity = .precise
        confidence = .high
        radius = nil
        requiresConfirmation = false
      case .reviewInterpolation:
        sourceKind = isEmbedded ? .embeddedTrackFix : .gpxInterpolated
        evidenceKind = .trajectoryInterval
        granularity = .coarse
        confidence = .low
        radius = nil
        requiresConfirmation = true
      case .stayCandidate:
        sourceKind = .stationaryBounded
        evidenceKind = .stationaryBounds
        granularity = .coarse
        confidence = .low
        radius = GeoMath.distance(
          from: legacyCandidate.startPoint.coordinate,
          to: legacyCandidate.endPoint?.coordinate ?? legacyCandidate.startPoint.coordinate
        )
        requiresConfirmation = true
      case .nearest:
        sourceKind = isEmbedded ? .embeddedTrackFix : .gpxInterpolated
        evidenceKind = isEmbedded ? .embeddedFix : .trajectoryPoint
        granularity = .coarse
        confidence = .low
        radius = nil
        requiresConfirmation = true
      case .ambiguous, .unmatched:
        continue
      }

      let evidence = LocationEvidence(
        id: "track:\(session.sourceID.rawValue):\(session.id):\(legacyCandidate.reason.rawValue)",
        kind: evidenceKind,
        sourceID: session.sourceID.rawValue,
        assetIDs: [asset.id],
        coordinate: coordinate,
        observedAtUTC: legacyCandidate.startPoint.timestamp,
        horizontalAccuracyMeters: maximumAccuracy(of: legacyCandidate),
        estimatedRadiusMeters: radius,
        hopCount: 0,
        note: legacyCandidate.reason.rawValue
      )
      result.append(
        candidate(
          asset: asset,
          coordinate: coordinate,
          elevationMeters: legacy.elevationMeters,
          sourceKind: sourceKind,
          granularity: granularity,
          confidence: confidence,
          radius: radius,
          requiresConfirmation: requiresConfirmation,
          sourcePriority: session.sourcePriority,
          ruleID: "v2.trajectory-\(legacy.mode.rawValue)",
          evidence: [evidence]
        )
      )
    }
    return result
  }

  // MARK: Single-hop propagation

  private struct Anchor: Sendable {
    let asset: CaptureAsset
    let candidate: LocationCandidate
  }

  private struct AnchorStreamKey: Hashable, Sendable {
    let activityID: ActivityID
    let cameraID: CameraID
  }

  private struct AnchorIndex: Sendable {
    let byActivity: [ActivityID: [Anchor]]
    let byStream: [AnchorStreamKey: [Anchor]]
  }

  private func makePrimaryAnchors(
    assets: [CaptureAsset],
    candidatesByAsset: [CaptureAssetID: [LocationCandidate]]
  ) -> [Anchor] {
    assets.compactMap { asset in
      let candidates = candidatesByAsset[asset.id, default: []]
        .filter {
          sourceRank($0.sourceKind) <= sourceRank(.embeddedTrackFix)
            && !$0.requiresConfirmation
            && ($0.confidence == .high || $0.confidence == .manual)
        }
        .sorted(by: candidateOrder)
      guard let selected = candidates.first else { return nil }
      return Anchor(asset: asset, candidate: selected)
    }
  }

  private func propagationCandidates(
    for asset: CaptureAsset,
    sameStreamAnchors: [Anchor],
    activityAnchors: [Anchor]
  ) -> [LocationCandidate] {
    let streamWindow = max(
      max(policy.burstWindowSeconds, policy.sequenceWindowSeconds),
      policy.stationaryMaximumSpanSeconds
    )
    let nearbyStreamAnchors = anchors(
      in: sameStreamAnchors,
      around: asset.captureTimeUTC,
      windowSeconds: streamWindow
    )
    let nearbyActivityAnchors = anchors(
      in: activityAnchors,
      around: asset.captureTimeUTC,
      windowSeconds: policy.crossCameraWindowSeconds
    )
    var result: [LocationCandidate] = []
    if let burst = burstCandidate(for: asset, anchors: nearbyStreamAnchors) {
      result.append(burst)
    }
    if let sequence = sequenceCandidate(for: asset, anchors: nearbyStreamAnchors) {
      result.append(sequence)
    }
    if let stationary = stationaryCandidate(for: asset, anchors: nearbyStreamAnchors) {
      result.append(stationary)
    }
    if let crossCamera = crossCameraCandidate(for: asset, anchors: nearbyActivityAnchors) {
      result.append(crossCamera)
    }
    return result
  }

  /// AnchorIndex 中的数组按时间升序排列。二分截取规则所需的最大时间窗口，
  /// 避免对同一活动里的全部锚点为每张照片重复做字符串和日期比较。
  private func anchors(
    in sortedAnchors: [Anchor],
    around time: Date,
    windowSeconds: TimeInterval
  ) -> ArraySlice<Anchor> {
    let lowerTime = time.addingTimeInterval(-windowSeconds)
    let upperTime = time.addingTimeInterval(windowSeconds)

    var lower = 0
    var upper = sortedAnchors.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if sortedAnchors[middle].asset.captureTimeUTC < lowerTime {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let lowerBound = lower

    lower = lowerBound
    upper = sortedAnchors.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if sortedAnchors[middle].asset.captureTimeUTC <= upperTime {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return sortedAnchors[lowerBound..<lower]
  }

  private func burstCandidate(for asset: CaptureAsset, anchors: ArraySlice<Anchor>)
    -> LocationCandidate?
  {
    guard let cameraID = asset.camera?.id, let activityID = asset.activityID else { return nil }
    let eligible = anchors.filter { anchor in
      guard anchor.asset.id != asset.id,
        anchor.asset.camera?.id == cameraID,
        anchor.asset.activityID == activityID,
        abs(anchor.asset.captureTimeUTC.timeIntervalSince(asset.captureTimeUTC))
          <= policy.burstWindowSeconds
      else { return false }
      if let targetSequence = asset.sequenceNumber,
        let anchorSequence = anchor.asset.sequenceNumber
      {
        return abs(targetSequence - anchorSequence) <= policy.burstMaximumSequenceGap
      }
      return true
    }
    guard !eligible.isEmpty,
      let dispersion = boundedDispersion(
        eligible.map(\.candidate.coordinate),
        maximumAllowed: policy.burstMaximumAnchorDispersionMeters
      )
    else { return nil }

    let ordered = eligible.sorted { anchorOrder($0, $1, targetTime: asset.captureTimeUTC) }
    guard let selected = ordered.first else { return nil }
    let representativeAnchors = Array(ordered.prefix(3))
    let radius: Double? = dispersion > 0 ? dispersion : nil
    return propagatedCandidate(
      asset: asset,
      selected: selected,
      agreeing: representativeAnchors,
      sourceKind: .burstPropagation,
      evidenceKind: .temporalNeighbor,
      granularity: .coarse,
      confidence: .medium,
      radius: radius,
      requiresConfirmation: true,
      ruleID: "v2.burst-single-hop"
    )
  }

  private func sequenceCandidate(for asset: CaptureAsset, anchors: ArraySlice<Anchor>)
    -> LocationCandidate?
  {
    guard let cameraID = asset.camera?.id, let activityID = asset.activityID else { return nil }
    let eligible = anchors.filter { anchor in
      guard anchor.asset.id != asset.id,
        anchor.asset.camera?.id == cameraID,
        anchor.asset.activityID == activityID,
        abs(anchor.asset.captureTimeUTC.timeIntervalSince(asset.captureTimeUTC))
          <= policy.sequenceWindowSeconds
      else { return false }
      if let targetSequence = asset.sequenceNumber,
        let anchorSequence = anchor.asset.sequenceNumber
      {
        return abs(targetSequence - anchorSequence) <= policy.sequenceMaximumGap
      }
      return true
    }
    guard !eligible.isEmpty else { return nil }
    let before = eligible.filter { $0.asset.captureTimeUTC <= asset.captureTimeUTC }
      .max(by: { $0.asset.captureTimeUTC < $1.asset.captureTimeUTC })
    let after = eligible.filter { $0.asset.captureTimeUTC >= asset.captureTimeUTC }
      .min(by: { $0.asset.captureTimeUTC < $1.asset.captureTimeUTC })

    if let before, let after, before.asset.id != after.asset.id {
      let distance = GeoMath.distance(
        from: before.candidate.coordinate,
        to: after.candidate.coordinate
      )
      guard distance <= policy.sequenceMaximumAnchorDispersionMeters else { return nil }
      let span = after.asset.captureTimeUTC.timeIntervalSince(before.asset.captureTimeUTC)
      let fraction =
        span > 0
        ? asset.captureTimeUTC.timeIntervalSince(before.asset.captureTimeUTC) / span : 0
      let coordinate = GeoMath.interpolate(
        from: before.candidate.coordinate,
        to: after.candidate.coordinate,
        fraction: fraction
      )
      let radius: Double? = distance
      return candidate(
        asset: asset,
        coordinate: coordinate,
        sourceKind: .sequencePropagation,
        granularity: .coarse,
        confidence: .medium,
        radius: radius,
        requiresConfirmation: true,
        ruleID: "v2.sequence-bounded-single-hop",
        evidence: neighborEvidence(
          asset: asset, anchors: [before, after], kind: .sequenceNeighbor,
          radius: radius, note: "bounded"
        )
          + inheritedEvidence(from: [before, after])
      )
    }

    guard
      let selected = eligible.sorted(by: {
        anchorOrder($0, $1, targetTime: asset.captureTimeUTC)
      }).first
    else { return nil }
    return propagatedCandidate(
      asset: asset,
      selected: selected,
      agreeing: [selected],
      sourceKind: .sequencePropagation,
      evidenceKind: .sequenceNeighbor,
      granularity: .coarse,
      confidence: .low,
      radius: nil,
      requiresConfirmation: true,
      ruleID: "v2.sequence-one-sided-single-hop"
    )
  }

  private func stationaryCandidate(for asset: CaptureAsset, anchors: ArraySlice<Anchor>)
    -> LocationCandidate?
  {
    guard let cameraID = asset.camera?.id, let activityID = asset.activityID else { return nil }
    let sameStream = anchors.filter {
      $0.asset.id != asset.id
        && $0.asset.camera?.id == cameraID
        && $0.asset.activityID == activityID
    }
    guard
      let before = sameStream.filter({ $0.asset.captureTimeUTC < asset.captureTimeUTC })
        .max(by: { $0.asset.captureTimeUTC < $1.asset.captureTimeUTC }),
      let after = sameStream.filter({ $0.asset.captureTimeUTC > asset.captureTimeUTC })
        .min(by: { $0.asset.captureTimeUTC < $1.asset.captureTimeUTC })
    else { return nil }

    let span = after.asset.captureTimeUTC.timeIntervalSince(before.asset.captureTimeUTC)
    let distance = GeoMath.distance(
      from: before.candidate.coordinate,
      to: after.candidate.coordinate
    )
    guard span <= policy.stationaryMaximumSpanSeconds,
      distance <= policy.stationaryMaximumAnchorDistanceMeters
    else { return nil }

    let fraction = asset.captureTimeUTC.timeIntervalSince(before.asset.captureTimeUTC) / span
    let coordinate = GeoMath.interpolate(
      from: before.candidate.coordinate,
      to: after.candidate.coordinate,
      fraction: fraction
    )
    let radius: Double? = distance
    return candidate(
      asset: asset,
      coordinate: coordinate,
      sourceKind: .stationaryBounded,
      granularity: .coarse,
      confidence: .medium,
      radius: radius,
      requiresConfirmation: true,
      ruleID: "v2.stationary-bounded-single-hop",
      evidence: neighborEvidence(
        asset: asset, anchors: [before, after], kind: .stationaryBounds,
        radius: radius, note: "bracketing anchors"
      )
        + inheritedEvidence(from: [before, after])
    )
  }

  private func crossCameraCandidate(for asset: CaptureAsset, anchors: ArraySlice<Anchor>)
    -> LocationCandidate?
  {
    guard let cameraID = asset.camera?.id, let activityID = asset.activityID else { return nil }
    let eligible = anchors.filter {
      $0.asset.id != asset.id
        && $0.asset.camera?.id != nil
        && $0.asset.camera?.id != cameraID
        && $0.asset.activityID == activityID
        && abs($0.asset.captureTimeUTC.timeIntervalSince(asset.captureTimeUTC))
          <= policy.crossCameraWindowSeconds
    }
    guard !eligible.isEmpty,
      let dispersion = boundedDispersion(
        eligible.map(\.candidate.coordinate),
        maximumAllowed: policy.crossCameraMaximumAnchorDispersionMeters
      )
    else { return nil }

    let hasStrongAnchor = eligible.contains {
      sourceRank($0.candidate.sourceKind) <= sourceRank(.gpxInterpolated)
    }
    let independentCameras = Set(eligible.compactMap { $0.asset.camera?.id }).count
    let independentSources = Set(eligible.map { $0.candidate.sourceKind }).count
    guard hasStrongAnchor || independentCameras >= 2 || independentSources >= 2 else { return nil }

    let ordered = eligible.sorted { anchorOrder($0, $1, targetTime: asset.captureTimeUTC) }
    var seenCameras: Set<CameraID> = []
    let representativeAnchors = ordered.filter { anchor in
      guard let cameraID = anchor.asset.camera?.id else { return false }
      return seenCameras.insert(cameraID).inserted
    }
    .prefix(3)
    guard let selected = representativeAnchors.first else { return nil }
    let radius: Double? = dispersion > 0 ? dispersion : nil
    return propagatedCandidate(
      asset: asset,
      selected: selected,
      agreeing: Array(representativeAnchors),
      sourceKind: .crossCamera,
      evidenceKind: .crossCameraNeighbor,
      granularity: .coarse,
      confidence: .low,
      radius: radius,
      requiresConfirmation: true,
      ruleID: "v2.cross-camera-single-hop"
    )
  }

  private func propagatedCandidate(
    asset: CaptureAsset,
    selected: Anchor,
    agreeing: [Anchor],
    sourceKind: LocationSourceKind,
    evidenceKind: LocationEvidenceKind,
    granularity: LocationGranularity,
    confidence: LocationDecisionConfidence,
    radius: Double?,
    requiresConfirmation: Bool,
    ruleID: String
  ) -> LocationCandidate {
    candidate(
      asset: asset,
      coordinate: selected.candidate.coordinate,
      elevationMeters: selected.candidate.elevationMeters,
      sourceKind: sourceKind,
      granularity: granularity,
      confidence: confidence,
      radius: radius,
      requiresConfirmation: requiresConfirmation,
      ruleID: ruleID,
      evidence: neighborEvidence(
        asset: asset, anchors: agreeing, kind: evidenceKind,
        radius: radius, note: "single-hop"
      )
        + inheritedEvidence(from: agreeing)
    )
  }

  private func inheritedEvidence(from anchors: [Anchor]) -> [LocationEvidence] {
    var seen: Set<String> = []
    return
      anchors
      .flatMap(\.candidate.evidence)
      .sorted { $0.id < $1.id }
      .filter { seen.insert($0.id).inserted }
  }

  private func neighborEvidence(
    asset: CaptureAsset,
    anchors: [Anchor],
    kind: LocationEvidenceKind,
    radius: Double?,
    note: String
  ) -> [LocationEvidence] {
    anchors.sorted(by: { $0.asset.id.rawValue < $1.asset.id.rawValue }).map { anchor in
      LocationEvidence(
        id: "neighbor:\(anchor.asset.id.rawValue):\(anchor.candidate.id)",
        kind: kind,
        sourceID: anchor.candidate.id,
        assetIDs: [asset.id, anchor.asset.id],
        coordinate: anchor.candidate.coordinate,
        observedAtUTC: anchor.asset.captureTimeUTC,
        estimatedRadiusMeters: radius,
        hopCount: 1,
        isCircular: false,
        note: note
      )
    }
  }

  // MARK: Region fallback and resolution

  private func regionCandidates(
    for asset: CaptureAsset,
    regions: [ActivityRegion]
  ) -> [LocationCandidate] {
    guard let activityID = asset.activityID else { return [] }
    return regions.filter {
      $0.activityID == activityID
        && $0.coordinate.isValid
        && $0.contains(asset.captureTimeUTC)
    }
    .sorted { $0.id < $1.id }
    .map { region in
      let isUserPin = region.source == .userPin
      let evidence = LocationEvidence(
        id: "region:\(region.id)",
        kind: .regionPrior,
        sourceID: region.id,
        assetIDs: [asset.id],
        coordinate: region.coordinate,
        estimatedRadiusMeters: max(region.radiusMeters, 1),
        hopCount: 0,
        note: region.label
      )
      return candidate(
        asset: asset,
        coordinate: region.coordinate,
        sourceKind: .activityRegion,
        granularity: region.radiusMeters <= 1_000 ? .coarse : .veryCoarse,
        confidence: isUserPin ? .manual : .low,
        radius: max(region.radiusMeters, 1),
        requiresConfirmation: !isUserPin,
        ruleID: "v2.activity-region-\(region.source.rawValue)",
        evidence: [evidence]
      )
    }
  }

  private func resolve(asset: CaptureAsset, candidates: [LocationCandidate])
    -> LocationResolution
  {
    let sorted = candidates.sorted(by: candidateOrder)
    guard let selected = sorted.first else {
      return LocationResolution(
        assetID: asset.id,
        status: .unresolved,
        selectedCandidate: nil,
        candidates: [],
        reasons: [.noCandidate],
        ruleVersion: policy.version
      )
    }

    if selected.sourceKind != .manualOverride {
      let comparable = sorted.filter {
        isComparableStrong($0) && isComparableStrong(selected)
      }
      let maximumConflict =
        comparable.map {
          GeoMath.distance(from: selected.coordinate, to: $0.coordinate)
        }.max() ?? 0
      if maximumConflict > policy.comparableCandidateConflictMeters {
        return LocationResolution(
          assetID: asset.id,
          status: .conflict,
          selectedCandidate: nil,
          candidates: sorted,
          reasons: [.comparableStrongCandidatesConflict],
          maximumComparableConflictMeters: maximumConflict,
          ruleVersion: policy.version
        )
      }
    }

    let needsReview =
      selected.requiresConfirmation
      || (selected.confidence != .high && selected.confidence != .manual)
    return LocationResolution(
      assetID: asset.id,
      status: needsReview ? .review : .resolved,
      selectedCandidate: selected,
      candidates: sorted,
      reasons: [needsReview ? .weakEvidenceNeedsReview : .selectedHighestPriority],
      ruleVersion: policy.version
    )
  }

  // MARK: Deterministic helpers

  private func candidate(
    asset: CaptureAsset,
    coordinate: GeoCoordinate,
    elevationMeters: Double? = nil,
    sourceKind: LocationSourceKind,
    granularity: LocationGranularity,
    confidence: LocationDecisionConfidence,
    radius: Double?,
    requiresConfirmation: Bool,
    sourcePriority: Int = 100,
    ruleID: String,
    evidence: [LocationEvidence]
  ) -> LocationCandidate {
    let sortedEvidence = evidence.sorted { $0.id < $1.id }
    let evidenceKey = sortedEvidence.map(\.id).joined(separator: "+")
    return LocationCandidate(
      id: "\(asset.id.rawValue)|\(sourceKind.rawValue)|\(ruleID)|\(evidenceKey)",
      assetID: asset.id,
      coordinate: coordinate,
      elevationMeters: elevationMeters,
      sourceKind: sourceKind,
      granularity: granularity,
      confidence: confidence,
      estimatedRadiusMeters: radius.map { max(1, $0) },
      requiresConfirmation: requiresConfirmation,
      sourcePriority: sourcePriority,
      ruleID: ruleID,
      evidence: sortedEvidence
    )
  }

  private func fixAge(
    for observation: AssetLocationObservation,
    asset: CaptureAsset
  ) -> TimeInterval? {
    guard let fixTime = observation.gpsTimestampUTC ?? observation.observedAtUTC else {
      return nil
    }
    return abs(asset.captureTimeUTC.timeIntervalSince(fixTime))
  }

  private func spatialGranularity(
    horizontalAccuracyMeters: Double?
  ) -> LocationGranularity {
    guard let accuracy = horizontalAccuracyMeters else { return .coarse }
    if accuracy <= 25 { return .precise }
    if accuracy <= 500 { return .coarse }
    return .veryCoarse
  }

  private func maximumAccuracy(of candidate: MatchCandidate) -> Double? {
    [
      candidate.startPoint.horizontalAccuracyMeters,
      candidate.endPoint?.horizontalAccuracyMeters,
    ].compactMap { $0 }.max()
  }

  private func boundedDispersion(
    _ coordinates: [GeoCoordinate],
    maximumAllowed: Double
  ) -> Double? {
    guard coordinates.count > 1 else { return 0 }
    let latitudes = coordinates.map(\.latitude)
    let longitudes = coordinates.map(\.longitude)
    guard let minimumLatitude = latitudes.min(), let maximumLatitude = latitudes.max(),
      let minimumLongitude = longitudes.min(), let maximumLongitude = longitudes.max()
    else { return 0 }
    if maximumLongitude - minimumLongitude <= 180 {
      let conservativeDiagonal = GeoMath.distance(
        from: GeoCoordinate(latitude: minimumLatitude, longitude: minimumLongitude),
        to: GeoCoordinate(latitude: maximumLatitude, longitude: maximumLongitude)
      )
      if conservativeDiagonal <= maximumAllowed {
        return conservativeDiagonal
      }
    }
    var maximum = 0.0
    for first in 0..<(coordinates.count - 1) {
      for second in (first + 1)..<coordinates.count {
        let distance = GeoMath.distance(from: coordinates[first], to: coordinates[second])
        guard distance <= maximumAllowed else { return nil }
        maximum = max(maximum, distance)
      }
    }
    return maximum
  }

  private func deduplicated(_ candidates: [LocationCandidate]) -> [LocationCandidate] {
    var seen: Set<String> = []
    return candidates.sorted(by: candidateOrder).filter { seen.insert($0.id).inserted }
  }

  private func isComparableStrong(_ candidate: LocationCandidate) -> Bool {
    sourceRank(candidate.sourceKind) <= sourceRank(.embeddedTrackFix)
      && !candidate.requiresConfirmation
  }

  private func sourceRank(_ source: LocationSourceKind) -> Int {
    switch source {
    case .manualOverride: 0
    case .directSensor: 10
    case .sameAsset: 20
    case .gpxExact: 30
    case .gpxInterpolated: 40
    case .embeddedFreshFix: 50
    case .embeddedTrackFix: 60
    case .burstPropagation: 70
    case .sequencePropagation: 80
    case .stationaryBounded: 80
    case .crossCamera: 90
    case .activityRegion: 100
    }
  }

  private func granularityRank(_ granularity: LocationGranularity) -> Int {
    switch granularity {
    case .exact: 0
    case .precise: 10
    case .coarse: 20
    case .veryCoarse: 30
    }
  }

  private func candidateOrder(_ left: LocationCandidate, _ right: LocationCandidate) -> Bool {
    let leftIsCircular = left.evidence.contains(where: \.isCircular)
    let rightIsCircular = right.evidence.contains(where: \.isCircular)
    if leftIsCircular != rightIsCircular {
      return !leftIsCircular
    }
    let leftRank = sourceRank(left.sourceKind)
    let rightRank = sourceRank(right.sourceKind)
    if leftRank != rightRank { return leftRank < rightRank }
    if left.sourcePriority != right.sourcePriority {
      return left.sourcePriority < right.sourcePriority
    }
    if left.requiresConfirmation != right.requiresConfirmation {
      return !left.requiresConfirmation
    }
    let leftGranularity = granularityRank(left.granularity)
    let rightGranularity = granularityRank(right.granularity)
    if leftGranularity != rightGranularity { return leftGranularity < rightGranularity }
    if left.estimatedRadiusMeters != right.estimatedRadiusMeters {
      switch (left.estimatedRadiusMeters, right.estimatedRadiusMeters) {
      case (let left?, let right?): return left < right
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): break
      }
    }
    return left.id < right.id
  }

  private func assetOrder(_ left: CaptureAsset, _ right: CaptureAsset) -> Bool {
    if left.captureTimeUTC != right.captureTimeUTC {
      return left.captureTimeUTC < right.captureTimeUTC
    }
    return left.id.rawValue < right.id.rawValue
  }

  private func makeAnchorIndex(_ anchors: [Anchor]) -> AnchorIndex {
    var byActivity: [ActivityID: [Anchor]] = [:]
    var byStream: [AnchorStreamKey: [Anchor]] = [:]
    for anchor in anchors {
      if let activityID = anchor.asset.activityID {
        byActivity[activityID, default: []].append(anchor)
      }
      if let key = anchorStreamKey(for: anchor.asset) {
        byStream[key, default: []].append(anchor)
      }
    }
    for key in Array(byActivity.keys) {
      byActivity[key]?.sort { $0.asset.captureTimeUTC < $1.asset.captureTimeUTC }
    }
    for key in Array(byStream.keys) {
      byStream[key]?.sort { $0.asset.captureTimeUTC < $1.asset.captureTimeUTC }
    }
    return AnchorIndex(byActivity: byActivity, byStream: byStream)
  }

  private func anchorStreamKey(for asset: CaptureAsset) -> AnchorStreamKey? {
    guard let activityID = asset.activityID, let cameraID = asset.camera?.id else { return nil }
    return AnchorStreamKey(activityID: activityID, cameraID: cameraID)
  }

  private func anchorOrder(_ left: Anchor, _ right: Anchor, targetTime: Date) -> Bool {
    if candidateOrder(left.candidate, right.candidate) { return true }
    if candidateOrder(right.candidate, left.candidate) { return false }
    let leftDelta = abs(left.asset.captureTimeUTC.timeIntervalSince(targetTime))
    let rightDelta = abs(right.asset.captureTimeUTC.timeIntervalSince(targetTime))
    if leftDelta != rightDelta { return leftDelta < rightDelta }
    return left.asset.id.rawValue < right.asset.id.rawValue
  }
}
