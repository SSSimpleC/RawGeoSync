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
    case .results: "验证写入结果"
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
  var trackURL: URL?
  var photoDirectoryURL: URL?
  var timeZoneIdentifier = "Asia/Shanghai"
  var cameraClockOffsetSeconds = 0
  var outputMode: OutputMode = .xmpSidecar
  var existingGPSPolicy: ExistingGPSPolicy = .skip

  var isReady: Bool { trackURL != nil && photoDirectoryURL != nil }

  var timeZone: TimeZone {
    TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
  }
}

enum OutputMode: String, CaseIterable, Identifiable, Sendable {
  case xmpSidecar

  var id: String { rawValue }
  var title: String { "XMP Sidecar（推荐）" }
}

enum ExistingGPSPolicy: String, CaseIterable, Identifiable, Sendable {
  case skip
  case review

  var id: String { rawValue }

  var title: String {
    switch self {
    case .skip: "跳过已有 GPS"
    case .review: "标记为待确认"
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
  case unmatched

  var id: String { rawValue }

  var title: String {
    switch self {
    case .reliable: "可靠"
    case .review: "待确认"
    case .unmatched: "未匹配"
    }
  }

  var systemImage: String {
    switch self {
    case .reliable: "checkmark.circle.fill"
    case .review: "exclamationmark.triangle.fill"
    case .unmatched: "questionmark.circle.fill"
    }
  }
}

enum MatchMethod: String, Sendable {
  case interpolated
  case stationary
  case previousPoint
  case nextPoint
  case midpoint
  case manual
  case unavailable

  var title: String {
    switch self {
    case .interpolated: "轨迹插值"
    case .stationary: "停留点"
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
  case verified
  case skipped
  case failed
  case undone

  var title: String {
    switch self {
    case .pending: "等待应用"
    case .verified: "已复读验证"
    case .skipped: "已跳过"
    case .failed: "失败"
    case .undone: "已撤销"
    }
  }
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
}

struct PhotoMatch: Identifiable, Hashable, Sendable {
  let id: UUID
  var fileURL: URL
  var capturedAt: Date
  var previousTrackPoint: GeoCoordinate?
  var nextTrackPoint: GeoCoordinate?
  var coordinate: GeoCoordinate?
  var confidence: MatchConfidence
  var method: MatchMethod
  var sourceLocationAccuracy: SourceLocationAccuracy
  var note: String
  var verification: VerificationState = .pending

  var fileName: String { fileURL.lastPathComponent }
}

struct AnalysisSnapshot: Sendable {
  var matches: [PhotoMatch]
  var trackCoordinates: [GeoCoordinate]

  var reliableCount: Int { matches.count(where: { $0.confidence == .reliable }) }
  var reviewCount: Int { matches.count(where: { $0.confidence == .review }) }
  var unmatchedCount: Int { matches.count(where: { $0.confidence == .unmatched }) }
}

enum ConfidenceFilter: String, CaseIterable, Identifiable {
  case all
  case reliable
  case review
  case unmatched

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "全部"
    case .reliable: "可靠"
    case .review: "待确认"
    case .unmatched: "未匹配"
    }
  }

  func includes(_ match: PhotoMatch) -> Bool {
    switch self {
    case .all: true
    case .reliable: match.confidence == .reliable
    case .review: match.confidence == .review
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
  var startedAt: Date
  var finishedAt: Date
  var appliedCount: Int
  var verifiedCount: Int
  var skippedCount: Int
  var failedCount: Int
  var outputDirectoryURL: URL?
  var isUndone = false
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
