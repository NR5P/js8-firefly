import SwiftUI
import JS8Core

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            #if os(macOS)
            DesktopLayout()
            #else
            if sizeClass == .regular { DesktopLayout() } else { PhoneLayout() }
            #endif
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .overlay(alignment: .top) { BannerView() }
        .sheet(isPresented: Binding(get: { !model.settings.hasOnboarded }, set: { _ in })) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .onAppear { model.start() }
    }
}

/// iPhone: tabbed layout.
struct PhoneLayout: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LiveTab()
                .tabItem { Label("Live", systemImage: "waveform") }
                .tag(0)
            ChatTab()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(1)
            NavigationStack {
                StationsView(onSelect: { tab = 1 })
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal)
                    .background(Theme.backgroundGradient.ignoresSafeArea())
                    .navigationTitle("Stations")
            }
            .tabItem { Label("Stations", systemImage: "person.2.wave.2.fill") }
            .tag(2)
            NavigationStack {
                InboxView()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal)
                    .background(Theme.backgroundGradient.ignoresSafeArea())
                    .navigationTitle("Inbox")
            }
            .tabItem { Label("Inbox", systemImage: "tray.full.fill") }
            .badge(model.inbox.filter { $0.type == "UNREAD" }.count)
            .tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
    }
}

struct LiveTab: View {
    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            VStack(spacing: 10) {
                WaterfallView()
                    .frame(height: 190)
                BandActivityView()
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            ComposeBar()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
    }
}

struct ChatTab: View {
    @Environment(AppModel.self) private var model
    @State private var onlySelected = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            WaterfallView(showSpectrum: false)
                .frame(height: 70)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            HStack {
                SectionHeader(title: "Conversation", icon: "bubble.left.and.bubble.right")
                if !model.selectedCallsign.isEmpty {
                    Toggle("Only \(model.selectedCallsign)", isOn: $onlySelected)
                        .toggleStyle(.button)
                        .font(.caption)
                }
                Button { model.clearConversation() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            ConversationView(filterCallsign: onlySelected ? model.selectedCallsign : nil)
                .frame(maxHeight: .infinity, alignment: .top)
            ComposeBar()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
    }
}

/// Mac / iPad: JS8Call-style console with waterfall, band activity,
/// conversation and heard stations side by side.
struct DesktopLayout: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var showInbox = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HeaderView()
                HStack(spacing: 14) {
                    Button { showInbox = true } label: {
                        Image(systemName: "tray.full.fill")
                            .overlay(alignment: .topTrailing) {
                                let n = model.inbox.filter { $0.type == "UNREAD" }.count
                                if n > 0 {
                                    Text("\(n)").font(.system(size: 9, weight: .bold)).padding(3)
                                        .background(Circle().fill(Theme.tx)).offset(x: 8, y: -8)
                                }
                            }
                    }
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
                .buttonStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
                .background(Theme.bg2.opacity(0.92))
            }
            .fixedSize(horizontal: false, vertical: true)

            WaterfallView()
                .frame(height: 210)
                .padding(10)

            HStack(alignment: .top, spacing: 10) {
                Card { BandActivityView() }
                    .frame(minWidth: 280, idealWidth: 360)
                VStack(spacing: 8) {
                    Card(padding: 4) { ConversationView() }
                    ComposeBar()
                }
                .frame(minWidth: 380)
                Card { StationsView() }
                    .frame(minWidth: 250, idealWidth: 300)
            }
            .padding([.horizontal, .bottom], 10)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
            .frame(minWidth: 560, minHeight: 640)
        }
        .sheet(isPresented: $showInbox) {
            NavigationStack {
                InboxView()
                    .padding()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInbox = false } } }
            }
            .frame(minWidth: 520, minHeight: 480)
        }
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if let e = model.lastError {
                bannerLabel(e, icon: "exclamationmark.triangle.fill", color: Theme.tx)
                    .onTapGesture { model.dismissError() }
            }
            if let b = model.banner {
                bannerLabel(b, icon: "info.circle.fill", color: Theme.accent)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        model.banner = nil
                    }
            }
        }
        .padding(.top, 50)
        .animation(.spring, value: model.banner)
        .animation(.spring, value: model.lastError)
    }

    private func bannerLabel(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(Theme.rounded(13, .semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(color.opacity(0.92)))
            .foregroundStyle(Theme.bg)
            .shadow(radius: 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var call = ""
    @State private var grid = ""

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image("Logo")
                .resizable()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: Color(red: 0.84, green: 1.0, blue: 0.36).opacity(0.35), radius: 24)
            Text("JS8 Firefly").font(Theme.rounded(38, .heavy)).foregroundStyle(Theme.text)
            Text("Keyboard-to-keyboard weak-signal messaging.\nFully compatible with JS8Call stations.")
                .multilineTextAlignment(.center)
                .font(Theme.rounded(15))
                .foregroundStyle(Theme.dim)
            VStack(spacing: 12) {
                TextField("Your callsign", text: $call)
                    .uppercaseInput()
                    .onChange(of: call) { _, v in if v != v.uppercased() { call = v.uppercased() } }
                    .font(Theme.mono(20, .bold))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardHi))
                TextField("Grid locator (e.g. EM73)", text: $grid)
                    .uppercaseInput()
                    .font(Theme.mono(18))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardHi))
            }
            .frame(maxWidth: 360)
            Button {
                model.settings.station.callsign = call.uppercased().trimmingCharacters(in: .whitespaces)
                model.settings.station.grid = formatGrid(grid)
                model.settings.hasOnboarded = true
                model.requestNotificationPermission()
            } label: {
                Text("Get on the air")
                    .font(Theme.rounded(17, .bold))
                    .frame(maxWidth: 360)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent))
                    .foregroundStyle(Theme.bg)
            }
            .buttonStyle(.plain)
            .disabled(call.count < 3 || !GridMath.isValid(grid))
            .opacity(call.count < 3 || !GridMath.isValid(grid) ? 0.5 : 1)
            Button("Just listen for now") {
                model.settings.hasOnboarded = true
                model.requestNotificationPermission()
            }
                .font(Theme.rounded(14))
                .foregroundStyle(Theme.dim)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func formatGrid(_ g: String) -> String {
        let t = g.trimmingCharacters(in: .whitespaces)
        guard t.count >= 4 else { return t.uppercased() }
        let head = t.prefix(4).uppercased()
        let tail = t.dropFirst(4).lowercased()
        return head + tail
    }
}
