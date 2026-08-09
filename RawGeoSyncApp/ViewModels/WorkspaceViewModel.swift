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
  @Published var isPreparingWrite = false
  @Published var isApplying = false
  @Published var isUndoing = false
  @Published var isManualPlacementEnabled = false
  @Published var report: ApplicationReport?
  @Published var writePreview: WritePreview?
  @Published var errorMessage: String?
  @Published var recoveryMessage: String?

  let service: any GeoWorkflowServicing
  private var operationTask: Task<Void, Never>?

  init(service: any GeoWorkflowServicing) {
    self.service = service
    Task { [weak self] in
      guard let self else { return }
      do {
        let count = try await service.interruptedTransactionCount()
        if count > 0 {
          recoveryMessage =
            "发现 \(count) 个未完成或撤销失败的事务。RawGeoSync 不会自动继续或覆盖文件；事务清单与备份已保留，可在确认现场状态后处理。"
        }
      } catch {
        // 启动恢复检查失败不应阻止只读分析；实际写入仍会执行完整预检。
      }
    }
  }

  var isBusy: Bool { isAnalyzing || isPreparingWrite || isApplying || isUndoing }

  var filteredMatches: [PhotoMatch] {
    matches.filter { match in
      confidenceFilter.includes(match)
        && (searchText.isEmpty || match.fileName.localizedStandardContains(searchText))
    }
  }

  var reliableCount: Int { matches.count(where: { $0.confidence == .reliable }) }
  var reviewCount: Int { matches.count(where: { $0.confidence == .review }) }
  var unmatchedCount: Int { matches.count(where: { $0.confidence == .unmatched }) }
  var writableCount: Int {
    matches.count(where: { $0.isSelectedForWrite && $0.coordinate != nil })
  }

  var checkedPhotoCount: Int {
    matches.count(where: { $0.isSelectedForWrite })
  }

  var areAllFilteredPhotosChecked: Bool {
    !filteredMatches.isEmpty && filteredMatches.allSatisfy(\.isSelectedForWrite)
  }

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
            selectedMatches = []
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

  func prepareApply() {
    guard canApply else { return }
    operationTask?.cancel()
    errorMessage = nil
    isPreparingWrite = true
    progressMessage = "检查文件摘要与现有 XMP…"
    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        let preview = try await service.previewWrite(
          matches: matches,
          configuration: configuration
        )
        for index in matches.indices
        where preview.conflictFileURLs.contains(matches[index].fileURL.standardizedFileURL) {
          matches[index].hasExistingGPS = true
          matches[index].isSelectedForWrite = false
          matches[index].confidence = .review
          matches[index].note = "检测到已有不同 GPS，已取消选择；重新勾选表示明确授权替换"
        }
        writePreview = preview
      } catch is CancellationError {
        progressMessage = "已取消"
      } catch {
        errorMessage = error.localizedDescription
      }
      isPreparingWrite = false
      operationTask = nil
    }
  }

  func confirmApply() {
    writePreview = nil
    apply()
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
        matches[index].isSelectedForWrite = true
      }
    }
    isManualPlacementEnabled = false
  }

  func clearSelection() {
    selectedMatches.removeAll()
    isManualPlacementEnabled = false
  }

  func toggleFilteredPhotoCheckmarks() {
    let visibleIDs = Set(filteredMatches.map(\.id))
    let shouldSelect = !areAllFilteredPhotosChecked
    for index in matches.indices {
      guard visibleIDs.contains(matches[index].id) else { continue }
      if shouldSelect {
        matches[index].isSelectedForWrite = true
        if matches[index].hasExistingGPS {
          matches[index].note = "已通过全选明确授权用匹配位置替换现有 GPS"
        }
      } else {
        matches[index].isSelectedForWrite = false
      }
    }
  }

  func setWriteSelection(_ selected: Bool, for id: PhotoMatch.ID) {
    guard let index = matches.firstIndex(where: { $0.id == id }) else { return }
    matches[index].isSelectedForWrite = selected
    if selected, matches[index].hasExistingGPS {
      matches[index].note = "已明确授权用匹配位置替换现有 GPS"
    }
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
    writePreview = nil
    errorMessage = nil
    progressFraction = 0
    progressMessage = ""
    isAnalyzing = false
    isPreparingWrite = false
    isApplying = false
    isUndoing = false
    isManualPlacementEnabled = false
  }
}
