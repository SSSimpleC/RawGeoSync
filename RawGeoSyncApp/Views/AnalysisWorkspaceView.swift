import MapKit
import SwiftUI

struct AnalysisWorkspaceView: View {
  @EnvironmentObject private var workspace: WorkspaceViewModel

  var body: some View {
    VStack(spacing: 0) {
      analysisToolbar
      Divider()
      summaryStrip
      Divider()

      HSplitView {
        matchList
          .frame(minWidth: 600, idealWidth: 720)
        MatchMapView()
          .frame(minWidth: 360, idealWidth: 480)
      }

      Divider()
      actionFooter
    }
    .overlay {
      if workspace.isApplying {
        ProgressOverlay(
          title: "正在创建并复读验证 XMP",
          message: workspace.progressMessage,
          fraction: workspace.progressFraction,
          cancel: workspace.cancelCurrentOperation
        )
      }
    }
  }

  private var analysisToolbar: some View {
    HStack(spacing: 12) {
      Button {
        workspace.returnToSources()
      } label: {
        Label("返回设置", systemImage: "chevron.backward")
      }

      Divider().frame(height: 20)

      Picker("筛选", selection: $workspace.confidenceFilter) {
        ForEach(ConfidenceFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 300)

      TextField("搜索文件名", text: $workspace.searchText)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 230)

      Spacer()

      Button("选择可见项") {
        workspace.selectVisible()
      }
      Button("清除选择") {
        workspace.clearSelection()
      }
      .disabled(workspace.selectedMatches.isEmpty)
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
    .background(.bar)
  }

  private var summaryStrip: some View {
    HStack(spacing: 10) {
      MetricCard(
        title: "全部照片",
        value: "\(workspace.matches.count)",
        systemImage: "photo.stack",
        tint: .cyan
      )
      MetricCard(
        title: "可靠匹配",
        value: "\(workspace.reliableCount)",
        systemImage: "checkmark.circle.fill",
        tint: .green
      )
      MetricCard(
        title: "需要确认",
        value: "\(workspace.reviewCount)",
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      )
      MetricCard(
        title: "将跳过",
        value: "\(workspace.unmatchedCount)",
        systemImage: "questionmark.circle.fill",
        tint: .red
      )
    }
    .padding(10)
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private var matchList: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("匹配预览")
          .font(.headline)
        Text("\(workspace.filteredMatches.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if !workspace.selectedMatches.isEmpty {
          Text("已选择 \(workspace.selectedMatches.count) 项")
            .font(.caption.weight(.medium))
            .foregroundStyle(.cyan)
        }
      }
      .padding(.horizontal, 14)
      .frame(height: 40)

      Divider()

      Table(workspace.filteredMatches, selection: $workspace.selectedMatches) {
        TableColumn("照片") { match in
          HStack(spacing: 7) {
            Image(systemName: "photo")
              .foregroundStyle(.secondary)
            Text(match.fileName)
              .font(.body.monospaced())
              .lineLimit(1)
          }
        }
        .width(min: 132, ideal: 158)

        TableColumn("拍摄时间") { match in
          Text(formattedCaptureDate(match.capturedAt))
            .font(.callout.monospacedDigit())
        }
        .width(min: 132, ideal: 144)

        TableColumn("置信度") { match in
          ConfidenceBadge(confidence: match.confidence)
        }
        .width(min: 80, ideal: 88)

        TableColumn("方式") { match in
          Text(match.method.title)
            .font(.callout)
        }
        .width(min: 72, ideal: 82)

        TableColumn("坐标 / 源定位精度") { match in
          VStack(alignment: .leading, spacing: 1) {
            Text(match.coordinate?.shortDescription ?? "—")
              .font(.caption.monospacedDigit())
            if match.coordinate == nil {
              Text(match.note)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
            } else {
              Text(match.sourceLocationAccuracy.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        .width(min: 150, ideal: 190)
      }
      .alternatingRowBackgrounds(.enabled)
    }
  }

  private var actionFooter: some View {
    HStack(spacing: 12) {
      if workspace.service.isSimulation {
        Label("演示服务不会写入文件", systemImage: "hammer")
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Label("原始 RAW 保持只读", systemImage: "lock.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if workspace.unmatchedCount > 0 {
        Text("\(workspace.unmatchedCount) 张未匹配照片将安全跳过")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button {
        workspace.apply()
      } label: {
        Label("应用并验证 \(workspace.writableCount) 张", systemImage: "checkmark.shield")
          .frame(minWidth: 150)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!workspace.canApply)
    }
    .padding(.horizontal, 16)
    .frame(height: 60)
    .background(.bar)
  }

  private func formattedCaptureDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = workspace.configuration.timeZone
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter.string(from: date)
  }
}

private struct MatchMapView: View {
  @EnvironmentObject private var workspace: WorkspaceViewModel
  @State private var cameraPosition: MapCameraPosition = .automatic

  private var positionedMatches: [PhotoMatch] {
    workspace.matches.filter { $0.coordinate != nil }
  }

  var body: some View {
    VStack(spacing: 0) {
      mapToolbar
      Divider()

      MapReader { proxy in
        Map(position: $cameraPosition) {
          if workspace.trackCoordinates.count > 1 {
            MapPolyline(coordinates: workspace.trackCoordinates.map(\.clCoordinate))
              .stroke(.cyan.opacity(0.7), lineWidth: 3)
          }

          ForEach(positionedMatches) { match in
            if let coordinate = match.coordinate {
              Annotation(match.fileName, coordinate: coordinate.clCoordinate, anchor: .bottom) {
                Button {
                  workspace.selectedMatches = [match.id]
                } label: {
                  ZStack {
                    Circle()
                      .fill(pinColor(for: match))
                      .frame(width: workspace.selectedMatches.contains(match.id) ? 19 : 13)
                    Circle()
                      .stroke(.white, lineWidth: 2)
                      .frame(width: workspace.selectedMatches.contains(match.id) ? 19 : 13)
                  }
                  .shadow(radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .help(match.fileName)
              }
              .annotationTitles(.hidden)
            }
          }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
          MapCompass()
          MapScaleView()
        }
        .contentShape(Rectangle())
        .gesture(
          SpatialTapGesture()
            .onEnded { value in
              guard workspace.isManualPlacementEnabled,
                let coordinate = proxy.convert(value.location, from: .local)
              else { return }
              workspace.applyStrategy(
                .manual(
                  GeoCoordinate(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    altitude: nil
                  )
                )
              )
            }
        )
        .overlay(alignment: .top) {
          if workspace.isManualPlacementEnabled {
            Label("在地图上单击，为所选照片指定位置", systemImage: "mappin.and.ellipse")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(.regularMaterial, in: Capsule())
              .shadow(radius: 5, y: 2)
              .padding(.top, 12)
          }
        }
      }
    }
  }

  private var mapToolbar: some View {
    VStack(spacing: 8) {
      HStack {
        Text("地图校正")
          .font(.headline)
        Spacer()
        Text(
          workspace.selectedMatches.isEmpty
            ? "先在左侧选择照片" : "批量处理 \(workspace.selectedMatches.count) 张"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      HStack(spacing: 6) {
        Button("前点") {
          workspace.applyStrategy(.previousPoint)
        }
        Button("后点") {
          workspace.applyStrategy(.nextPoint)
        }
        Button("中点") {
          workspace.applyStrategy(.midpoint)
        }
        Divider().frame(height: 18)
        Button {
          workspace.isManualPlacementEnabled.toggle()
        } label: {
          Label("手工位置", systemImage: "mappin.and.ellipse")
        }
        .buttonStyle(.bordered)
        .tint(workspace.isManualPlacementEnabled ? .orange : .cyan)
        Spacer()
      }
      .disabled(workspace.selectedMatches.isEmpty)
    }
    .padding(.horizontal, 12)
    .frame(height: 72)
    .background(.bar)
  }

  private func pinColor(for match: PhotoMatch) -> Color {
    if workspace.selectedMatches.contains(match.id) { return .cyan }
    switch match.confidence {
    case .reliable: return .green
    case .review: return .orange
    case .unmatched: return .red
    }
  }
}
