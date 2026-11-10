import SwiftUI

@main
struct JS8CallApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.live)
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
