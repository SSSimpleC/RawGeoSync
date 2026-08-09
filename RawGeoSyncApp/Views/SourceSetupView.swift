import AppKit
import SwiftUI

struct SourceSetupView: View {
  @EnvironmentObject private var workspace: WorkspaceViewModel

  private let commonTimeZones = [
    "Asia/Shanghai",
    "Asia/Hong_Kong",
    "Asia/Tokyo",
    "Europe/London",
    "America/Los_Angeles",
    "UTC",
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 7) {
          Text("让每张 RAW 回到拍摄地")
            .font(.largeTitle.weight(.semibold))
          Text("先选择手机轨迹与相机文件夹。RawGeoSync 会在写入前展示每张照片的匹配依据和风险。")
            .font(.title3)
            .foregroundStyle(.secondary)
        }

        if workspace.service.isSimulation {
          SimulationBanner(label: workspace.service.implementationLabel)
        }

        HStack(spacing: 16) {
          SourcePickerCard(
            title: "GPX 轨迹目录",
            description: "自动读取目录内与照片时间窗口相关的全部 GPX。",
            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
            url: workspace.configuration.gpxDirectoryURL,
            actionTitle: "选择 GPX 目录…",
            action: chooseGPXFolder,
            onDropURL: setGPXFolderURL
          )
          SourcePickerCard(
            title: "照片活动或 RAW 目录",
            description: "可选择活动根目录或单个相机目录；递归发现专有 RAW 和只读证据。",
            systemImage: "camera.aperture",
            url: workspace.configuration.photoDirectoryURL,
            actionTitle: "选择文件夹…",
            action: choosePhotoFolder,
            onDropURL: setPhotoFolderURL
          )
        }
        .frame(minHeight: 190)

        GroupBox("匹配、时间与写入策略") {
          Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
            GridRow {
              SettingLabel(
                title: "匹配策略",
                detail: workspace.configuration.matchingStrategy.detail,
                systemImage: "scope"
              )
              Picker("", selection: $workspace.configuration.matchingStrategy) {
                ForEach(MatchingStrategy.allCases) { strategy in
                  Text(strategy.title).tag(strategy)
                }
              }
              .labelsHidden()
              .frame(maxWidth: 270, alignment: .leading)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
              SettingLabel(
                title: "拍摄地时区",
                detail: "用于把相机墙上时间转换为 UTC",
                systemImage: "globe.asia.australia"
              )
              Picker("", selection: $workspace.configuration.timeZoneIdentifier) {
                ForEach(commonTimeZones, id: \.self) { identifier in
                  Text(identifier).tag(identifier)
                }
              }
              .labelsHidden()
              .frame(maxWidth: 270, alignment: .leading)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
              SettingLabel(
                title: "相机时钟偏移",
                detail: "仅参与匹配，不修改 RAW 的拍摄时间",
                systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90"
              )
              HStack {
                TextField(
                  "秒",
                  value: $workspace.configuration.cameraClockOffsetSeconds,
                  format: .number
                )
                .frame(width: 90)
                Text("秒")
                  .foregroundStyle(.secondary)
                Stepper(
                  "",
                  value: $workspace.configuration.cameraClockOffsetSeconds,
                  in: -43_200...43_200,
                  step: 1
                )
                .labelsHidden()
              }
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
              SettingLabel(
                title: "输出方式",
                detail: "仅为 NEF、ARW 等专有 RAW 创建同名 sidecar",
                systemImage: "doc.badge.gearshape"
              )
              Picker("", selection: $workspace.configuration.outputMode) {
                ForEach(OutputMode.allCases) { mode in
                  Text(mode.title).tag(mode)
                }
              }
              .labelsHidden()
              .frame(maxWidth: 270, alignment: .leading)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
              SettingLabel(
                title: "写入海拔",
                detail: "默认关闭；仅可靠匹配且轨迹提供海拔时写入",
                systemImage: "mountain.2"
              )
              Toggle("写入可用海拔", isOn: $workspace.configuration.writeAltitude)
                .toggleStyle(.switch)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
              SettingLabel(
                title: "已有坐标",
                detail: "新来源可证明更强时自动采用；未知外部 XMP 仍受保护",
                systemImage: "shield.checkered"
              )
              Text("强来源优先，未知来源保护")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 270, alignment: .leading)
            }
          }
          .padding(.top, 8)
        }

        HStack {
          Label("分析阶段不会写入任何文件", systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            workspace.analyze()
          } label: {
            Label("分析匹配", systemImage: "sparkles")
              .frame(minWidth: 104)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!workspace.configuration.isReady || workspace.isBusy)
        }
      }
      .frame(maxWidth: 980)
      .padding(.horizontal, 32)
      .padding(.vertical, 30)
      .frame(maxWidth: .infinity)
    }
    .overlay {
      if workspace.isAnalyzing {
        ProgressOverlay(
          title: "正在分析拍摄活动",
          message: workspace.progressMessage,
          fraction: workspace.progressFraction,
          cancel: workspace.cancelCurrentOperation
        )
      }
    }
  }

  private func chooseGPXFolder() {
    let panel = NSOpenPanel()
    panel.title = "选择存放 GPX 轨迹的目录"
    panel.prompt = "选择目录"
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    setGPXFolderURL(url)
  }

  private func choosePhotoFolder() {
    let panel = NSOpenPanel()
    panel.title = "选择包含 RAW 文件的文件夹"
    panel.prompt = "选择文件夹"
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    setPhotoFolderURL(url)
  }

  private func setGPXFolderURL(_ url: URL) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      workspace.errorMessage = "请选择包含 GPX 文件的目录。"
      return
    }
    workspace.configuration.gpxDirectoryURL = url
  }

  private func setPhotoFolderURL(_ url: URL) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      workspace.errorMessage = "请选择包含 RAW 文件的文件夹。"
      return
    }
    workspace.configuration.photoDirectoryURL = url
  }
}

private struct SettingLabel: View {
  let title: String
  let detail: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.cyan)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SourcePickerCard: View {
  let title: String
  let description: String
  let systemImage: String
  let url: URL?
  let actionTitle: String
  let action: () -> Void
  let onDropURL: (URL) -> Void
  @State private var isDropTarget = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: systemImage)
          .font(.title2)
          .foregroundStyle(.cyan)
        Text(title)
          .font(.headline)
        Spacer()
        if url != nil {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }

      Text(description)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let url {
        HStack(spacing: 8) {
          Image(systemName: "doc.fill")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(url.lastPathComponent)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            Text(url.deletingLastPathComponent().path(percentEncoded: false))
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
      } else {
        Text("也可以把文件或文件夹拖到这里")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      Button(actionTitle, action: action)
        .buttonStyle(.bordered)
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      isDropTarget ? Color.cyan.opacity(0.11) : Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(
          isDropTarget ? Color.cyan : Color.secondary.opacity(0.18),
          style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: url == nil ? [7] : []))
    }
    .dropDestination(for: URL.self) { items, _ in
      guard let first = items.first else { return false }
      onDropURL(first)
      return true
    } isTargeted: { isTargeted in
      isDropTarget = isTargeted
    }
  }
}
