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
            title: "已应用",
            value: "\(report?.appliedCount ?? 0)",
            systemImage: "square.and.arrow.down",
            tint: .cyan
          )
          MetricCard(
            title: "复读验证通过",
            value: "\(report?.verifiedCount ?? 0)",
            systemImage: "checkmark.seal.fill",
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

        GroupBox("验证详情") {
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
            Text(report?.isUndone == true ? "本次应用已撤销" : "下一步：导入 Lightroom Classic")
              .font(.headline)
            Text(report?.outputDirectoryURL?.path(percentEncoded: false) ?? "未记录输出目录")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer()

          Button("返回预览") {
            workspace.stage = .analysis
          }

          Button {
            workspace.undo()
          } label: {
            Label(
              workspace.isUndoing ? "正在撤销…" : "撤销本次应用",
              systemImage: "arrow.uturn.backward.circle"
            )
          }
          .disabled(report?.isUndone != false || workspace.isBusy)

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
          systemName: report?.isUndone == true
            ? "arrow.uturn.backward.circle.fill" : "checkmark.seal.fill"
        )
        .font(.system(size: 42))
        .foregroundStyle(report?.isUndone == true ? .orange : .green)
      }
      Text(report?.isUndone == true ? "已安全撤销" : "地理信息已应用并验证")
        .font(.largeTitle.weight(.semibold))
      Text(report?.isUndone == true ? "已恢复应用前的 sidecar 状态。" : "原始 RAW 未被修改；所有成功项均已复读确认。")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
  }

  private func color(for state: VerificationState) -> Color {
    switch state {
    case .verified: .green
    case .skipped: .orange
    case .failed: .red
    case .undone: .orange
    case .pending: .secondary
    }
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
    case .verified: "checkmark.circle.fill"
    case .skipped: "forward.end.circle.fill"
    case .failed: "xmark.circle.fill"
    case .undone: "arrow.uturn.backward.circle.fill"
    case .pending: "clock.fill"
    }
  }

  private var color: Color {
    switch state {
    case .verified: .green
    case .skipped: .orange
    case .failed: .red
    case .undone: .orange
    case .pending: .secondary
    }
  }
}
