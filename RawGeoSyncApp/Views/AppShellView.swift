import SwiftUI

struct AppShellView: View {
  @EnvironmentObject private var workspace: WorkspaceViewModel

  var body: some View {
    VStack(spacing: 0) {
      WorkflowHeader(stage: workspace.stage)
      Divider()

      Group {
        switch workspace.stage {
        case .sources:
          SourceSetupView()
        case .analysis:
          AnalysisWorkspaceView()
        case .results:
          ApplyResultView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.cyan)
    .alert(
      "RawGeoSync 无法继续",
      isPresented: Binding(
        get: { workspace.errorMessage != nil },
        set: { if !$0 { workspace.errorMessage = nil } }
      ),
      actions: {
        Button("好", role: .cancel) {
          workspace.errorMessage = nil
        }
      },
      message: {
        Text(workspace.errorMessage ?? "未知错误")
      }
    )
  }
}

private struct WorkflowHeader: View {
  let stage: WorkflowStage

  var body: some View {
    HStack(spacing: 18) {
      HStack(spacing: 10) {
        Image(systemName: "location.viewfinder")
          .font(.title2.weight(.semibold))
          .foregroundStyle(.cyan)
        VStack(alignment: .leading, spacing: 1) {
          Text("RawGeoSync")
            .font(.headline)
          Text("RAW 地理信息预检与写入")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 28)

      HStack(spacing: 0) {
        ForEach(WorkflowStage.allCases) { item in
          StepItem(stage: item, currentStage: stage)
          if item != WorkflowStage.allCases.last {
            Capsule()
              .fill(item.rawValue < stage.rawValue ? Color.cyan : Color.secondary.opacity(0.22))
              .frame(width: 44, height: 2)
              .padding(.horizontal, 8)
          }
        }
      }

      Spacer(minLength: 28)

      Text("本地处理")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .help("轨迹与照片不会上传到网络")
    }
    .padding(.horizontal, 20)
    .frame(height: 68)
    .background(.bar)
  }
}

private struct StepItem: View {
  let stage: WorkflowStage
  let currentStage: WorkflowStage

  private var isCurrent: Bool { stage == currentStage }
  private var isComplete: Bool { stage.rawValue < currentStage.rawValue }

  var body: some View {
    HStack(spacing: 8) {
      ZStack {
        Circle()
          .fill(isCurrent || isComplete ? Color.cyan : Color.secondary.opacity(0.16))
          .frame(width: 28, height: 28)
        Image(systemName: isComplete ? "checkmark" : stage.systemImage)
          .font(.caption.weight(.bold))
          .foregroundStyle(isCurrent || isComplete ? Color.black.opacity(0.76) : .secondary)
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(stage.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(isCurrent ? .primary : .secondary)
        Text(stage.subtitle)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }
}
