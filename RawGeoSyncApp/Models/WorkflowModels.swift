import CoreLocation
import Foundation

enum WorkflowStage: Int, CaseIterable, Identifiable, Sendable {
  case sources
  case analysis
  case results

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .sources: "准备"
    case .analysis: "分析"
    case .results: "完成"
    }
  }

  var subtitle: String {
    switch self {
    case .sources: "选择轨迹与照片"
    case .analysis: "预览并修正匹配"
    case .results: "查看输出结果"
    }
  }

  var systemImage: String {
    switch self {
    case .sources: "tray.full"
    case .analysis: "point.3.connected.trianglepath.dotted"
    case .results: "checkmark.seal"
    }
  }
}

struct SourceConfiguration: Equatable, Sendable {
  var gpxSourceURL: URL?
  var photoDirectoryURL: URL?
  var timeZoneIdentifier = "Asia/Shanghai"
  var cameraClockOffsetSeconds = 0
  var cameraClockOffsetsByID: [String: Int] = [:]
  var writeAltitude = false
  var matchingStrategy: MatchingStrategy = .coverage
  var outputMode: OutputMode = .lightroomCatalogBridge

  var isReady: Bool { gpxSourceURL != nil && photoDirectoryURL != nil }

  var timeZone: TimeZone {
    TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
  }
}

enum MatchingStrategy: String, CaseIterable, Identifiable, Sendable {
  case precision
  case balanced
  case coverage

  var id: String { rawValue }

  var title: String {
    switch self {
    case .precision: "精度优先"
    case .balanced: "平衡"
    case .coverage: "覆盖优先"
    }
  }

  var detail: String {
    switch self {
    case .precision:
      "只自动采用新鲜传感器、精确轨迹与密集轨迹结果"
    case .balanced:
      "生成轨迹、停留和照片序列候选，区域级结果需主动开启"
    case .coverage:
      "为每张照片尽量给出候选；粗略结果仍需批量确认"
    }
  }
}

enum OutputMode: String, CaseIterable, Identifiable, Sendable {
  case lightroomCatalogBridge
  case xmpSidecar

  var id: String { rawValue }

  var title: String {
    switch self {
    case .lightroomCatalogBridge: "Lightroom Classic 单清单"
    case .xmpSidecar: "XMP Sidecar（兼容模式）"
    }
  }

  var detail: String {
    switch self {
    case .lightroomCatalogBridge:
      "在照片目录只生成一份位置清单，再由 Lightroom Classic 插件批量写入目录"
    case .xmpSidecar:
      "为每张专有 RAW 创建或更新同名 XMP；适合不依赖 Lightroom 目录的工作流"
    }
  }

  var actionTitle: String {
    switch self {
    case .lightroomCatalogBridge: "导出清单"
    case .xmpSidecar: "写入 XMP"
    }
  }
}

struct GeoCoordinate: Hashable, Codable, Sendable {
  var latitude: Double
  var longitude: Double
  var altitude: Double?

  var clCoordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  var shortDescription: String {
    String(format: "%.5f, %.5f", latitude, longitude)
  }

  static func midpoint(_ lhs: GeoCoordinate, _ rhs: GeoCoordinate) -> GeoCoordinate {
    GeoCoordinate(
      latitude: (lhs.latitude + rhs.latitude) / 2,
      longitude: (lhs.longitude + rhs.longitude) / 2,
      altitude: midpointAltitude(lhs.altitude, rhs.altitude)
    )
  }

  private static func midpointAltitude(_ lhs: Double?, _ rhs: Double?) -> Double? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): (lhs + rhs) / 2
    case (.some(let value), .none), (.none, .some(let value)): value
    case (.none, .none): nil
    }
  }
}

enum MatchConfidence: String, CaseIterable, Identifiable, Sendable {
  case reliable
  case review
  case coarse
  case unmatched

  var id: String { rawValue }

  var title: String {
    switch self {
    case .reliable: "可靠"
    case .review: "待确认"
    case .coarse: "粗略区域"
    case .unmatched: "未匹配"
    }
  }

  var systemImage: String {
    switch self {
    case .reliable: "checkmark.circle.fill"
    case .review: "exclamationmark.triangle.fill"
    case .coarse: "map.fill"
    case .unmatched: "questionmark.circle.fill"
    }
  }
}

enum SpatialGranularity: String, Sendable {
  case sensor
  case track
  case photoCluster
  case activity
  case region
  case manual
  case unavailable

  var title: String {
    switch self {
    case .sensor: "传感器级"
    case .track: "轨迹级"
    case .photoCluster: "照片簇级"
    case .activity: "活动级"
    case .region: "区域级"
    case .manual: "手工位置"
    case .unavailable: "无位置"
    }
  }
}

enum MatchMethod: String, Sendable {
  case directSensor
  case exact
  case interpolated
  case reviewInterpolation
  case sameAsset
  case auxiliaryFix
  case burstPropagation
  case sequencePropagation
  case crossCamera
  case stationary
  case activityRepresentative
  case regionRepresentative
  case nearest
  case previousPoint
  case nextPoint
  case midpoint
  case manual
  case unavailable

  var title: String {
    switch self {
    case .directSensor: "新鲜传感器 GPS"
    case .exact: "精确轨迹点"
    case .interpolated: "轨迹插值"
    case .reviewInterpolation: "待确认插值"
    case .sameAsset: "同一资产"
    case .auxiliaryFix: "辅助定位事件"
    case .burstPropagation: "连拍传播"
    case .sequencePropagation: "照片序列传播"
    case .crossCamera: "跨相机一致锚点"
    case .stationary: "停留点"
    case .activityRepresentative: "活动代表位置"
    case .regionRepresentative: "区域代表位置"
    case .nearest: "最近轨迹点"
    case .previousPoint: "前点"
    case .nextPoint: "后点"
    case .midpoint: "中点"
    case .manual: "手工位置"
    case .unavailable: "无可用轨迹"
    }
  }
}

enum VerificationState: String, Sendable {
  case pending
  case exported
  case verified
  case skipped
  case failed
  case undone

  var title: String {
    switch self {
    case .pending: "等待应用"
    case .exported: "已写入清单"
    case .verified: "已复读验证"
    case .skipped: "已跳过"
    case .failed: "失败"
    case .undone: "已撤销"
    }
  }
}

struct PhotoIdentity: Hashable, Sendable {
  var relativePath: String
  var fileSize: Int64?
  var exifDateTimeOriginal: String
  var subsecondTimeOriginal: String?
  var offsetTimeOriginal: String?
  var cameraMake: String?
  var cameraModel: String?
  var cameraSerialNumber: String?
  var cameraInternalSerialNumber: String?
  var shutterCount: Int?
}

enum SourceLocationAccuracy: Hashable, Sendable {
  case meters(Double)
  case notProvided

  var description: String {
    switch self {
    case .meters(let value):
      "源记录精度 ±\(value.formatted(.number.precision(.fractionLength(0)))) m"
    case .notProvided:
      "源未提供定位精度"
    }
  }

  var meters: Double? {
    if case .meters(let value) = self { return value }
    return nil
  }
}

struct PhotoMatch: Identifiable, Hashable, Sendable {
  let id: String
  var fileURL: URL
  var identity: PhotoIdentity? = nil
  var capturedAt: Date
  var previousTrackPoint: GeoCoordinate?
  var nextTrackPoint: GeoCoordinate?
  var coordinate: GeoCoordinate?
  var confidence: MatchConfidence
  var method: MatchMethod
  var granularity: SpatialGranularity
  var sourceLocationAccuracy: SourceLocationAccuracy
  var evidenceSummary: String
  var supportSpreadMeters: Double?
  var confirmationGroupID: String?
  var ruleVersion: String = "1.0"
  var sourceTimeLowerBound: Date?
  var sourceTimeUpperBound: Date?
  var temporalDistanceSeconds: TimeInterval?
  var trackFileSHA256: String? = nil
  var note: String
  var isSelectedForWrite: Bool
  var isWritableTarget: Bool
  var hasExistingGPS: Bool
  var hasProtectedExternalXMP: Bool
  var replacementExplicitlyAuthorized = false
  var verification: VerificationState = .pending

  var fileName: String { fileURL.lastPathComponent }
}

struct AnalysisSnapshot: Sendable {
  var matches: [PhotoMatch]
  var trackCoordinates: [GeoCoordinate]
  var warnings: [String] = []
  var clockSuggestions: [ClockSuggestionInfo] = []

  var reliableCount: Int { matches.count(where: { $0.confidence == .reliable }) }
  var reviewCount: Int { matches.count(where: { $0.confidence == .review }) }
  var coarseCount: Int { matches.count(where: { $0.confidence == .coarse }) }
  var unmatchedCount: Int { matches.count(where: { $0.confidence == .unmatched }) }
}

struct ClockSuggestionInfo: Identifiable, Hashable, Sendable {
  var id: String { cameraID }
  var cameraID: String
  var cameraLabel: String
  var cameraAheadBySeconds: Int
  var evidenceCount: Int
  var residualSeconds: TimeInterval
  var confidenceLabel: String
}

enum ConfidenceFilter: String, CaseIterable, Identifiable {
  case all
  case reliable
  case review
  case coarse
  case unmatched

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "全部"
    case .reliable: "可靠"
    case .review: "待确认"
    case .coarse: "粗略"
    case .unmatched: "未匹配"
    }
  }

  func includes(_ match: PhotoMatch) -> Bool {
    switch self {
    case .all: true
    case .reliable: match.confidence == .reliable
    case .review: match.confidence == .review
    case .coarse: match.confidence == .coarse
    case .unmatched: match.confidence == .unmatched
    }
  }
}

enum BatchAssignmentStrategy: Sendable {
  case previousPoint
  case nextPoint
  case midpoint
  case manual(GeoCoordinate)
}

struct ApplicationReport: Sendable {
  var transactionID: UUID?
  var startedAt: Date
  var finishedAt: Date
  var appliedCount: Int
  var verifiedCount: Int
  var skippedCount: Int
  var failedCount: Int
  var outputDirectoryURL: URL?
  var outputMode: OutputMode = .xmpSidecar
  var artifactURL: URL? = nil
  var isUndone = false

  var canUndo: Bool { outputMode == .xmpSidecar && transactionID != nil && !isUndone }
}

struct WritePreview: Identifiable, Sendable {
  let id = UUID()
  var selectedCount: Int
  var createCount: Int
  var updateCount: Int
  var alreadyAppliedCount: Int
  var conflictCount: Int
  var conflictFileURLs: Set<URL> = []
  var outputMode: OutputMode = .xmpSidecar
  var artifactURL: URL? = nil

  var writableCount: Int { createCount + updateCount }

  var title: String {
    switch outputMode {
    case .lightroomCatalogBridge: "确认单清单导出计划"
    case .xmpSidecar: "确认 XMP 写入计划"
    }
  }

  var confirmTitle: String {
    switch outputMode {
    case .lightroomCatalogBridge: "确认导出"
    case .xmpSidecar: "确认写入"
    }
  }

  var message: String {
    switch outputMode {
    case .lightroomCatalogBridge:
      "将把 \(writableCount) 张已勾选照片写入一份 Lightroom Classic 位置清单；"
        + "\(alreadyAppliedCount) 张内容未变化，\(conflictCount) 张因身份冲突将跳过。"
    case .xmpSidecar:
      "将新建 \(createCount) 个、更新 \(updateCount) 个 XMP；"
        + "\(alreadyAppliedCount) 个已包含相同位置，\(conflictCount) 个冲突将跳过。"
    }
  }
}

enum AnalysisEvent: Sendable {
  case progress(fraction: Double, message: String)
  case completed(AnalysisSnapshot)
}

enum ApplyEvent: Sendable {
  case progress(fraction: Double, message: String)
  case completed(matches: [PhotoMatch], report: ApplicationReport)
}

struct WorkflowFailure: LocalizedError, Sendable {
  var message: String
  var errorDescription: String? { message }
}
