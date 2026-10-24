import SwiftUI

@main
struct JS8CallApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandMenu("Station") {
                Button("Send CQ") { model.sendCQ() }.keyboardShortcut("q", modifiers: [.command, .shift])
                Button("Heartbeat") { model.toggleHeartbeat() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Halt TX") { model.halt() }.keyboardShortcut(.escape, modifiers: [])
            }
        }
        #endif
    }
}
