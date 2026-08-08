import SwiftUI

@main
struct RawGeoSyncDesktopApp: App {
  @StateObject private var workspace = WorkspaceViewModel(service: LiveGeoWorkflowService())

  var body: some Scene {
    WindowGroup {
      AppShellView()
        .environmentObject(workspace)
        .frame(minWidth: 1_080, minHeight: 700)
    }
    .defaultSize(width: 1_280, height: 820)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(after: .newItem) {
        Button("重新开始") {
          workspace.reset()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Divider()

        Button("取消当前任务") {
          workspace.cancelCurrentOperation()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!workspace.isBusy)
      }
    }
  }
}
