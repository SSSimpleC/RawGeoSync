import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
          Text("先选择手机轨迹文件（或目录）与相机文件夹。RawGeoSync 会在写入前展示每张照片的匹配依据和风险。")
            .font(.title3)
            .foregroundStyle(.secondary)
        }

        if workspace.service.isSimulation {
          SimulationBanner(label: workspace.service.implementationLabel)
        }

        HStack(spacing: 16) {
          SourcePickerCard(
            title: "GPX 轨迹",
            description: "可选择单个 GPX 文件，或自动读取目录内与照片时间窗口相关的全部 GPX。",
            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
            url: workspace.configuration.gpxSourceURL,
            actionTitle: "选择 GPX 文件或目录…",
            action: chooseGPXSource,
            onDropURL: setGPXSourceURL
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

        GroupBox("匹配、时间与输出策略") {
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
                detail: workspace.configuration.outputMode.detail,
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

            if workspace.configuration.outputMode == .lightroomCatalogBridge {
              GridRow {
                SettingLabel(
                  title: "Lightroom Classic 插件",
                  detail: "插件读取单清单，并在当前 Lightroom 目录中批量应用 GPS",
                  systemImage: "puzzlepiece.extension"
                )
                HStack(spacing: 10) {
                  Label(
                    workspace.pluginInstallationStatus.title,
                    systemImage: workspace.pluginInstallationStatus == .installed
                      ? "checkmark.circle.fill" : "puzzlepiece.extension"
                  )
                  .foregroundStyle(
                    workspace.pluginInstallationStatus == .installed ? .green : .secondary
                  )
                  if let actionTitle = workspace.pluginInstallationStatus.actionTitle {
                    Button(actionTitle) {
                      workspace.installOrUpdateLightroomPlugin()
                    }
                    .buttonStyle(.bordered)
                  }
                  Button("重新检查") {
                    workspace.refreshPluginInstallationStatus()
                  }
                  .buttonStyle(.link)
                }
                .frame(maxWidth: 330, alignment: .leading)
              }

              Divider().gridCellUnsizedAxes(.horizontal)
            }

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
                detail: workspace.configuration.outputMode == .lightroomCatalogBridge
                  ? "插件会在预览中明确列出冲突；执行后以本次清单位置覆盖"
                  : "新来源可证明更强时自动采用；未知外部 XMP 仍受保护",
                systemImage: "shield.checkered"
              )
              Text(
                workspace.configuration.outputMode == .lightroomCatalogBridge
                  ? "本次清单覆盖，可在插件中整批撤销" : "强来源优先，未知来源保护"
              )
              .foregroundStyle(.secondary)
              .frame(maxWidth: 270, alignment: .leading)
            }
          }
          .padding(.top, 8)
        }

        if workspace.configuration.outputMode == .lightroomCatalogBridge {
          Label(
            "如果 Lightroom Classic 已开启“自动将更改写入 XMP”，应用目录位置后仍可能由 Lightroom 自行创建 sidecar。",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundStyle(.orange)
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
    .onAppear {
      workspace.refreshPluginInstallationStatus()
    }
  }

  private func chooseGPXSource() {
    let panel = NSOpenPanel()
    panel.title = "选择 GPX 轨迹文件或目录"
    panel.prompt = "选择"
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    setGPXSourceURL(url)
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

  @discardableResult
  private func setGPXSourceURL(_ url: URL) -> Bool {
    do {
      guard !(try LiveGeoWorkflowService.gpxFiles(at: url)).isEmpty else {
        workspace.errorMessage = "所选来源中没有 GPX 文件。"
        return false
      }
      workspace.configuration.gpxSourceURL = url.standardizedFileURL
      workspace.errorMessage = nil
      return true
    } catch {
      workspace.errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  private func setPhotoFolderURL(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      workspace.errorMessage = "请选择包含 RAW 文件的文件夹。"
      return false
    }
    workspace.configuration.photoDirectoryURL = url.standardizedFileURL
    workspace.errorMessage = nil
    return true
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
  let onDropURL: (URL) -> Bool
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
      return onDropURL(first)
    } isTargeted: { isTargeted in
      isDropTarget = isTargeted
    }
  }
}
