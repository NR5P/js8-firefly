import SwiftUI
import JS8Core

/// JS8Call's "Band Activity" table.
struct BandActivityView: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Band Activity", icon: "waveform",
                          trailing: AnyView(
                            Button { model.clearBand() } label: { Image(systemName: "trash").font(.caption) }
                                .buttonStyle(.plain).foregroundStyle(Theme.faint)))
            if model.bandRows.isEmpty {
                EmptyStateView(icon: "dot.radiowaves.left.and.right", title: "Listening…",
                               subtitle: "Decodes appear here at the end of each period.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.bandRows) { row in
                            BandRow(row: row, selected: abs(row.offset - model.settings.offset) <= row.submode.rxThreshold,
                                    watch: model.settings.watch(matching: row.text))
                                .onTapGesture { model.setOffset(row.offset) }
                                .contextMenu {
                                    Button("Move to \(row.offset) Hz") { model.setOffset(row.offset) }
                                    ForEach(Varicode.parseCallsigns(row.text).prefix(3), id: \.self) { call in
                                        Button("Select \(call)") { model.selectedCallsign = call }
                                    }
                                }
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }
}

struct BandRow: View {
    let row: BandActivityRow
    let selected: Bool
    var watch: WatchItem?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(row.offset)")
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(selected ? Theme.warn : Theme.text)
                Text(Format.snr(row.snr))
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.snrColor(row.snr))
            }
            .frame(width: 44, alignment: .trailing)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.modeColor(row.submode))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.text)
                    .font(Theme.mono(13))
                    .foregroundStyle(row.isDirectedToMe ? Theme.tx : Theme.text)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(JS8Station.since(row.utc, now: AppClock.now()))
                    Text(row.submode.name)
                    Text(String(format: "%+.1fs", row.tdrift))
                    if let watch { WatchTag(item: watch) }
                }
                .font(Theme.mono(9))
                .foregroundStyle(Theme.faint)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(row.isDirectedToMe ? Theme.tx.opacity(0.12) : (selected ? Theme.warn.opacity(0.08) : Theme.cardHi.opacity(0.55)))
        )
        .watchGlow(watch, since: row.utc, fill: !row.isDirectedToMe)
    }
}

/// JS8Call's "Call Activity" (heard stations) list.
struct StationsView: View {
    @EnvironmentObject private var model: AppModel
    var onSelect: (() -> Void)?
    @State private var filter = ""
    @State private var copied = false
    @AppStorage("stationsShowMap") private var showMap = false

    private var shown: [CallDetail] {
        model.calls.filter { filter.isEmpty || $0.call.contains(filter.uppercased()) }
    }

    /// Copies every listed callsign as one comma-separated line (no spaces),
    /// so other apps can split it on commas.
    private func copyAll() {
        Pasteboard.copy(shown.map(\.call).joined(separator: ","))
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Stations Heard", icon: "person.2.wave.2",
                          trailing: AnyView(HStack(spacing: 10) {
                            Button { showMap.toggle() } label: {
                                Label(showMap ? "List" : "Map", systemImage: showMap ? "list.bullet" : "map")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.faint)
                            .accessibilityHint(showMap ? "Shows heard stations as a list" : "Shows heard stations on a map by grid")
                            if !model.calls.isEmpty {
                                Button(action: copyAll) {
                                    Label(copied ? "Copied" : "Copy All",
                                          systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(copied ? Theme.accent : Theme.faint)
                                .accessibilityHint("Copies all heard callsigns, separated by commas")
                            }
                            Text("\(model.calls.count)").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                          }))
            if showMap {
                StationMapView(onSelect: onSelect)
            } else if model.calls.isEmpty {
                EmptyStateView(icon: "antenna.radiowaves.left.and.right", title: "No stations yet",
                               subtitle: "Heartbeats, CQs and directed traffic will populate this list.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(shown) { cd in StationListRow(cd: cd, onSelect: onSelect) }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }
}

/// A heard station in a list: tap to select it, long-press for actions.
struct StationListRow: View {
    @EnvironmentObject private var model: AppModel
    let cd: CallDetail
    var onSelect: (() -> Void)?
    @State private var storeFor: StoreTarget?

    var body: some View {
        StationRow(cd: cd, myGrid: model.settings.station.grid,
                   selected: model.selectedCallsign == cd.call,
                   watch: model.settings.watch(matching: cd.call))
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectedCallsign = model.selectedCallsign == cd.call ? "" : cd.call
                if model.selectedCallsign == cd.call { onSelect?() }
            }
            .contextMenu {
                Button("Select \(cd.call)") { model.selectedCallsign = cd.call }
                Button("Move to \(cd.offset) Hz") { model.setOffset(cd.offset) }
                Button("Ask SNR?") { model.selectedCallsign = cd.call; model.send("SNR?") }
                Button("Ask GRID?") { model.selectedCallsign = cd.call; model.send("GRID?") }
                Button("Store Message for \(cd.call)…") { storeFor = StoreTarget(call: cd.call) }
            }
            .sheet(item: $storeFor) { t in StoreMessageSheet(to: t.call) }
    }
}

struct StationRow: View {
    let cd: CallDetail
    let myGrid: String
    let selected: Bool
    var watch: WatchItem?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(selected ? Theme.accent : Theme.cardHi)
                Text(String(cd.call.prefix(1)))
                    .font(Theme.rounded(15, .bold))
                    .foregroundStyle(selected ? Theme.bg : Theme.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cd.call).font(Theme.mono(14, .bold)).foregroundStyle(Theme.text)
                    if cd.cqTimestamp != nil { Chip(text: "CQ", color: Theme.rx) }
                    if cd.ackTimestamp != nil { Chip(text: "ACK", color: Theme.accent2) }
                    if !cd.through.isEmpty { Chip(text: "via \(cd.through)", color: Theme.faint) }
                    if let watch { Image(systemName: "eye.fill").font(.caption2).foregroundStyle(watch.color.color) }
                }
                HStack(spacing: 8) {
                    if !cd.grid.isEmpty { Text(cd.grid.trimmingCharacters(in: .whitespaces)) }
                    if let db = GridMath.distanceBearing(from: myGrid, to: cd.grid.trimmingCharacters(in: .whitespaces)) {
                        Text("\(Int(db.km)) km  \(Int(db.bearing))°")
                    }
                    Text("\(cd.offset) Hz")
                }
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.snr(cd.snr) + " dB")
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.snrColor(cd.snr))
                Text(JS8Station.since(cd.utc, now: AppClock.now()))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.12) : Theme.cardHi.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
        .watchGlow(watch, since: cd.utc, cornerRadius: 12, fill: !selected)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
                .pulseEffect()
            Text(title).font(Theme.rounded(15, .semibold)).foregroundStyle(Theme.text)
            Text(subtitle).font(Theme.rounded(12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding()
    }
}
