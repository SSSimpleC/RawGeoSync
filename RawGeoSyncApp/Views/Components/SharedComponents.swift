import SwiftUI

struct MetricCard: View {
  let title: String
  let value: String
  let systemImage: String
  let tint: Color
  var detail: String? = nil

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(value)
          .font(.title3.weight(.semibold).monospacedDigit())
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(
      .quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

struct ConfidenceBadge: View {
  let confidence: MatchConfidence

  private var tint: Color {
    switch confidence {
    case .reliable: .green
    case .review: .orange
    case .coarse: .purple
    case .unmatched: .red
    }
  }

  var body: some View {
    Label(confidence.title, systemImage: confidence.systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
      .labelStyle(.titleAndIcon)
  }
}

struct SimulationBanner: View {
  let label: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "hammer.fill")
        .foregroundStyle(.orange)
      Text("当前使用\(label)：可体验完整交互，但不会创建或修改任何 XMP 文件。")
        .font(.caption)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.orange.opacity(0.22))
    }
  }
}

struct ProgressOverlay: View {
  let title: String
  let message: String
  let fraction: Double
  let cancel: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.28)
        .ignoresSafeArea()
      VStack(spacing: 16) {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .frame(width: 300)
        VStack(spacing: 4) {
          Text(title)
            .font(.headline)
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Button("取消", action: cancel)
          .keyboardShortcut(.cancelAction)
      }
      .padding(28)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .shadow(radius: 22, y: 8)
    }
  }
}
