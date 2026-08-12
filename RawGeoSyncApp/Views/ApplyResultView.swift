import AppKit
import SwiftUI

struct ApplyResultView: View {
  @EnvironmentObject private var workspace: WorkspaceViewModel

  private var report: ApplicationReport? { workspace.report }

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        statusHeader

        if workspace.service.isSimulation {
          SimulationBanner(label: workspace.service.implementationLabel)
        }

        HStack(spacing: 12) {
          MetricCard(
            title: report?.outputMode == .lightroomCatalogBridge ? "清单记录" : "已应用",
            value: "\(report?.appliedCount ?? 0)",
            systemImage: "square.and.arrow.down",
            tint: .cyan
          )
          MetricCard(
            title: report?.outputMode == .lightroomCatalogBridge ? "单清单文件" : "复读验证通过",
            value: report?.outputMode == .lightroomCatalogBridge
              ? (report?.artifactURL == nil ? "0" : "1") : "\(report?.verifiedCount ?? 0)",
            systemImage: report?.outputMode == .lightroomCatalogBridge
              ? "doc.text.fill" : "checkmark.seal.fill",
            tint: .green
          )
          MetricCard(
            title: "安全跳过",
            value: "\(report?.skippedCount ?? 0)",
            systemImage: "forward.end.fill",
            tint: .orange
          )
          MetricCard(
            title: "失败",
            value: "\(report?.failedCount ?? 0)",
            systemImage: "xmark.octagon.fill",
            tint: .red
          )
        }

        GroupBox(report?.outputMode == .lightroomCatalogBridge ? "清单详情" : "验证详情") {
          VStack(spacing: 0) {
            ForEach(workspace.matches) { match in
              HStack(spacing: 12) {
                VerificationIcon(state: match.verification)
                VStack(alignment: .leading, spacing: 2) {
                  Text(match.fileName)
                    .font(.body.monospaced())
                  Text(match.coordinate?.shortDescription ?? "无可靠坐标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(match.verification.title)
                  .font(.caption.weight(.medium))
                  .foregroundStyle(color(for: match.verification))
              }
              .padding(.vertical, 9)
              if match.id != workspace.matches.last?.id {
                Divider()
              }
            }
          }
          .padding(.horizontal, 8)
        }

        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(nextStepTitle)
              .font(.headline)
            Text(outputPath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer()

          Button("返回预览") {
            workspace.stage = .analysis
          }

          if report?.outputMode == .lightroomCatalogBridge {
            if let actionTitle = workspace.pluginInstallationStatus.actionTitle {
              Button(actionTitle) {
                workspace.installOrUpdateLightroomPlugin()
              }
            }
            Button {
              if let artifactURL = report?.artifactURL {
                NSWorkspace.shared.activateFileViewerSelecting([artifactURL])
              }
            } label: {
              Label("在访达中显示清单", systemImage: "folder")
            }
            .disabled(report?.artifactURL == nil)
            Button("打开 Lightroom Classic") {
              if let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.adobe.LightroomClassicCC7"
              ) {
                NSWorkspace.shared.open(appURL)
              } else {
                workspace.errorMessage = "未找到 Adobe Lightroom Classic。"
              }
            }
          } else {
            Button {
              workspace.undo()
            } label: {
              Label(
                workspace.isUndoing ? "正在撤销…" : "撤销本次应用",
                systemImage: "arrow.uturn.backward.circle"
              )
            }
            .disabled(report?.canUndo != true || workspace.isBusy)
          }

          Button {
            workspace.reset()
          } label: {
            Label("开始新任务", systemImage: "plus")
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .frame(maxWidth: 980)
      .padding(.horizontal, 32)
      .padding(.vertical, 30)
      .frame(maxWidth: .infinity)
    }
  }

  private var statusHeader: some View {
    VStack(spacing: 10) {
      ZStack {
        Circle()
          .fill((report?.isUndone == true ? Color.orange : Color.green).opacity(0.13))
          .frame(width: 76, height: 76)
        Image(
          systemName: statusIcon
        )
        .font(.system(size: 42))
        .foregroundStyle(report?.isUndone == true ? .orange : .green)
      }
      Text(statusTitle)
        .font(.largeTitle.weight(.semibold))
      Text(statusDetail)
        .font(.title3)
        .foregroundStyle(.secondary)
    }
  }

  private func color(for state: VerificationState) -> Color {
    switch state {
    case .exported: .cyan
    case .verified: .green
    case .skipped: .orange
    case .failed: .red
    case .undone: .orange
    case .pending: .secondary
    }
  }

  private var nextStepTitle: String {
    if report?.isUndone == true { return "本次应用已撤销" }
    if report?.outputMode == .lightroomCatalogBridge {
      return "下一步：在 Lightroom Classic 中运行 RawGeoSync 插件"
    }
    return "下一步：导入 Lightroom Classic"
  }

  private var statusTitle: String {
    if report?.isUndone == true { return "已安全撤销" }
    return report?.outputMode == .lightroomCatalogBridge
      ? "Lightroom Classic 位置清单已生成" : "地理信息已应用并验证"
  }

  private var statusIcon: String {
    if report?.isUndone == true { return "arrow.uturn.backward.circle.fill" }
    return report?.outputMode == .lightroomCatalogBridge
      ? "doc.badge.checkmark" : "checkmark.seal.fill"
  }

  private var outputPath: String {
    if let artifactURL = report?.artifactURL {
      return artifactURL.path(percentEncoded: false)
    }
    return report?.outputDirectoryURL?.path(percentEncoded: false) ?? "未记录输出位置"
  }

  private var statusDetail: String {
    if report?.isUndone == true { return "已恢复应用前的 sidecar 状态。" }
    if report?.outputMode == .lightroomCatalogBridge {
      return "原始 RAW 未被修改；清单仍需由插件写入当前 Lightroom 目录，应用后可整批撤销。"
    }
    return "原始 RAW 未被修改；所有成功项均已复读确认。"
  }
}

private struct VerificationIcon: View {
  let state: VerificationState

  var body: some View {
    Image(systemName: icon)
      .foregroundStyle(color)
      .frame(width: 24)
  }

  private var icon: String {
    switch state {
    case .exported: "doc.text.fill"
    case .verified: "checkmark.circle.fill"
    case .skipped: "forward.end.circle.fill"
    case .failed: "xmark.circle.fill"
    case .undone: "arrow.uturn.backward.circle.fill"
    case .pending: "clock.fill"
    }
  }

  private var color: Color {
    switch state {
    case .exported: .cyan
    case .verified: .green
    case .skipped: .orange
    case .failed: .red
    case .undone: .orange
    case .pending: .secondary
    }
  }
}
