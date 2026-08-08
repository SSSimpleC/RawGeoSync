import Foundation

@MainActor
final class WorkspaceViewModel: ObservableObject {
  @Published var stage: WorkflowStage = .sources
  @Published var configuration = SourceConfiguration()
  @Published var matches: [PhotoMatch] = []
  @Published var trackCoordinates: [GeoCoordinate] = []
  @Published var selectedMatches: Set<PhotoMatch.ID> = []
  @Published var confidenceFilter: ConfidenceFilter = .all
  @Published var searchText = ""
  @Published var progressFraction = 0.0
  @Published var progressMessage = ""
  @Published var isAnalyzing = false
  @Published var isApplying = false
  @Published var isUndoing = false
  @Published var isManualPlacementEnabled = false
  @Published var report: ApplicationReport?
  @Published var errorMessage: String?

  let service: any GeoWorkflowServicing
  private var operationTask: Task<Void, Never>?

  init(service: any GeoWorkflowServicing) {
    self.service = service
  }

  var isBusy: Bool { isAnalyzing || isApplying || isUndoing }

  var filteredMatches: [PhotoMatch] {
    matches.filter { match in
      confidenceFilter.includes(match)
        && (searchText.isEmpty || match.fileName.localizedStandardContains(searchText))
    }
  }

  var reliableCount: Int { matches.count(where: { $0.confidence == .reliable }) }
  var reviewCount: Int { matches.count(where: { $0.confidence == .review }) }
  var unmatchedCount: Int { matches.count(where: { $0.confidence == .unmatched }) }
  var writableCount: Int { matches.count(where: { $0.coordinate != nil }) }

  var canApply: Bool {
    writableCount > 0 && !isBusy
  }

  func analyze() {
    guard configuration.isReady else {
      errorMessage = "请先选择 GPX 文件和 RAW 文件夹。"
      return
    }

    operationTask?.cancel()
    errorMessage = nil
    isAnalyzing = true
    progressFraction = 0
    progressMessage = "准备分析…"

    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await event in service.analysisEvents(for: configuration) {
          try Task.checkCancellation()
          switch event {
          case .progress(let fraction, let message):
            progressFraction = fraction
            progressMessage = message
          case .completed(let snapshot):
            matches = snapshot.matches
            trackCoordinates = snapshot.trackCoordinates
            selectedMatches = Set(snapshot.matches.filter { $0.confidence != .reliable }.map(\.id))
            confidenceFilter = .all
            stage = .analysis
          }
        }
      } catch is CancellationError {
        progressMessage = "已取消"
      } catch {
        errorMessage = error.localizedDescription
      }
      isAnalyzing = false
      operationTask = nil
    }
  }

  func apply() {
    guard !matches.isEmpty else { return }
    operationTask?.cancel()
    errorMessage = nil
    isApplying = true
    progressFraction = 0
    progressMessage = "准备生成 XMP…"

    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await event in service.applyEvents(matches: matches, configuration: configuration) {
          try Task.checkCancellation()
          switch event {
          case .progress(let fraction, let message):
            progressFraction = fraction
            progressMessage = message
          case .completed(let updatedMatches, let completedReport):
            matches = updatedMatches
            report = completedReport
            stage = .results
          }
        }
      } catch is CancellationError {
        progressMessage = "已取消"
      } catch {
        errorMessage = error.localizedDescription
      }
      isApplying = false
      operationTask = nil
    }
  }

  func undo() {
    guard var currentReport = report, !currentReport.isUndone else { return }
    operationTask?.cancel()
    isUndoing = true
    errorMessage = nil
    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        matches = try await service.undo(report: currentReport, matches: matches)
        currentReport.isUndone = true
        report = currentReport
      } catch is CancellationError {
        progressMessage = "已取消"
      } catch {
        errorMessage = error.localizedDescription
      }
      isUndoing = false
      operationTask = nil
    }
  }

  func applyStrategy(_ strategy: BatchAssignmentStrategy) {
    guard !selectedMatches.isEmpty else { return }
    for index in matches.indices where selectedMatches.contains(matches[index].id) {
      let coordinate: GeoCoordinate?
      let method: MatchMethod

      switch strategy {
      case .previousPoint:
        coordinate = matches[index].previousTrackPoint
        method = .previousPoint
      case .nextPoint:
        coordinate = matches[index].nextTrackPoint
        method = .nextPoint
      case .midpoint:
        if let previous = matches[index].previousTrackPoint,
          let next = matches[index].nextTrackPoint
        {
          coordinate = .midpoint(previous, next)
        } else {
          coordinate = matches[index].previousTrackPoint ?? matches[index].nextTrackPoint
        }
        method = .midpoint
      case .manual(let manualCoordinate):
        coordinate = manualCoordinate
        method = .manual
      }

      if let coordinate {
        matches[index].coordinate = coordinate
        matches[index].method = method
        matches[index].confidence = .review
        matches[index].sourceLocationAccuracy = .notProvided
        matches[index].note = method == .manual ? "由用户在地图上手工指定" : "由用户批量指定为\(method.title)"
      }
    }
    isManualPlacementEnabled = false
  }

  func selectVisible() {
    selectedMatches = Set(filteredMatches.map(\.id))
  }

  func clearSelection() {
    selectedMatches.removeAll()
    isManualPlacementEnabled = false
  }

  func cancelCurrentOperation() {
    operationTask?.cancel()
  }

  func returnToSources() {
    cancelCurrentOperation()
    stage = .sources
  }

  func reset() {
    cancelCurrentOperation()
    stage = .sources
    configuration = SourceConfiguration()
    matches = []
    trackCoordinates = []
    selectedMatches = []
    report = nil
    errorMessage = nil
    progressFraction = 0
    progressMessage = ""
    isAnalyzing = false
    isApplying = false
    isUndoing = false
    isManualPlacementEnabled = false
  }
}
