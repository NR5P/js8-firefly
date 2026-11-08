import SwiftUI
import JS8Core

/// Offline base map drawn from WorldMap.bin (Natural Earth 1:50m, public
/// domain; rebuilt with tools/mapdata/build_map_data.py). Paths are in
/// degrees, x = longitude and y = -latitude.
struct WorldMap: @unchecked Sendable {
    var land = Path()
    var lakes = Path()
    var borders = Path()
    var states = Path()

    static let shared = WorldMap.load()

    private static func load() -> WorldMap {
        var map = WorldMap()
        guard let url = Bundle.main.url(forResource: "WorldMap", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return map }
        let b = [UInt8](data)
        guard b.count > 6, b[0...3] == [70, 70, 77, 80] else { return map }  // "FFMP"
        var i = 6
        func u32() -> Int? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        }
        func deg() -> CGFloat {
            defer { i += 2 }
            return CGFloat(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)) / 100
        }
        for _ in 0..<Int(b[5]) {
            guard i < b.count else { break }
            let kind = b[i]
            i += 1
            guard let rings = u32() else { break }
            var path = Path()
            for _ in 0..<rings {
                guard let n = u32(), n > 0, i + n * 4 <= b.count else { return map }
                for k in 0..<n {
                    let lon = deg(), lat = deg()
                    let p = CGPoint(x: lon, y: -lat)
                    if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                if kind < 2 { path.closeSubpath() }
            }
            switch kind {
            case 0: map.land = path
            case 1: map.lakes = path
            case 2: map.borders = path
            default: map.states = path
            }
        }
        return map
    }
}

/// What part of the world is on screen: a plate carrée projection with
/// longitude squeezed by `aspect` (the cosine of a reference latitude) so
/// shapes look right around the stations being shown.
struct MapCamera: Equatable {
    var lon: Double
    var lat: Double
    /// Points per degree of latitude.
    var scale: Double
    var aspect: Double

    static let maxScale = 700.0

    var xScale: Double { scale * aspect }

    func point(lon l: Double, lat t: Double, in size: CGSize) -> CGPoint {
        // Use whichever copy of the world is nearest the centre.
        let l = l + 360 * ((lon - l) / 360).rounded()
        return CGPoint(x: (l - lon) * xScale + size.width / 2, y: (lat - t) * scale + size.height / 2)
    }

    /// The degree-space to screen transform for the copy of the world shifted by `copy` × 360°.
    func transform(in size: CGSize, copy: Int) -> CGAffineTransform {
        CGAffineTransform(a: xScale, b: 0, c: 0, d: scale,
                          tx: size.width / 2 + xScale * (Double(copy) * 360 - lon),
                          ty: size.height / 2 + scale * lat)
    }

    /// Visible longitude and latitude ranges.
    func visible(in size: CGSize) -> (lon: ClosedRange<Double>, lat: ClosedRange<Double>) {
        let dx = size.width / 2 / xScale, dy = size.height / 2 / scale
        return (lon - dx...lon + dx, lat - dy...lat + dy)
    }

    static func minScale(in size: CGSize, aspect: Double) -> Double {
        max(0.3, min(size.width / (360 * aspect), size.height / 170))
    }

    mutating func clamp(in size: CGSize) {
        scale = min(max(scale, Self.minScale(in: size, aspect: aspect)), Self.maxScale)
        lat = min(max(lat, -80), 85)
        lon = (lon + 180).truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        lon -= 180
    }

    mutating func pan(by d: CGSize, in size: CGSize) {
        lon -= d.width / xScale
        lat += d.height / scale
        clamp(in: size)
    }

    /// Zoom by `factor`, keeping the spot under `anchor` where it is.
    mutating func zoom(by factor: Double, at anchor: CGPoint, in size: CGSize) {
        let ax = anchor.x - size.width / 2, ay = anchor.y - size.height / 2
        let l = lon + ax / xScale, t = lat - ay / scale
        scale *= factor
        clamp(in: size)
        lon = l - ax / xScale
        lat = t + ay / scale
        clamp(in: size)
    }
}

/// Heard stations that sent a grid, grouped by the square they're in.
struct MapMarker: Identifiable {
    let id: String
    let calls: [CallDetail]
    let lon: Double
    let lat: Double
    var latest: Date { calls.map(\.utc).max() ?? .distantPast }
}

/// Stations Heard on an offline map, placed by the grids they sent on air
/// (heartbeats, CQs and GRID replies), so it shows where they say they are.
struct StationMapView: View {
    @Environment(AppModel.self) private var model
    var onSelect: (() -> Void)?

    /// Where the user has panned or zoomed to; nil keeps every station in frame.
    @State private var camera: MapCamera?
    @State private var lastDrag: CGSize?
    @State private var lastZoom: CGFloat?
    @State private var picked: String?

    private let map = WorldMap.shared

    private var myGrid: String { model.settings.station.grid }

    private var markers: [MapMarker] {
        var groups: [String: [CallDetail]] = [:]
        for cd in model.calls {
            if let key = GridMath.mapKey(cd.grid) { groups[key, default: []].append(cd) }
        }
        return groups.compactMap { key, calls in
            guard let sq = GridMath.square(key) else { return nil }
            return MapMarker(id: key, calls: calls.sorted { $0.utc > $1.utc },
                             lon: sq.lon + sq.width / 2, lat: sq.lat + sq.height / 2)
        }
        .sorted { $0.latest < $1.latest }  // freshest drawn last, on top
    }

    private var withoutGrid: [CallDetail] {
        model.calls.filter { GridMath.mapKey($0.grid) == nil }
    }

    var body: some View {
        let markers = markers
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = geo.size
                let cam = currentCamera(markers, in: size)
                ZStack(alignment: .topTrailing) {
                    canvas(markers, cam)
                        .gesture(panAndZoom(markers, in: size))
                        .onTapGesture { pick(at: $0, in: markers, cam, size) }
                    controls(markers, in: size)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .onChange(of: markers.map(\.id)) { _, _ in
                if let p = picked, !markers.contains(where: { $0.id == p }) { picked = nil }
            }

            if let p = picked, let m = markers.first(where: { $0.id == p }) {
                pickedPanel(m)
            } else {
                summary(markers)
            }
        }
    }

    // MARK: Drawing

    private func canvas(_ markers: [MapMarker], _ cam: MapCamera?) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.ocean))
            guard let cam, size.width > 0 else { return }
            let vis = cam.visible(in: size)

            for copy in -1...1 where vis.lon.overlaps(Double(copy) * 360 - 180...Double(copy) * 360 + 180) {
                let t = cam.transform(in: size, copy: copy)
                ctx.fill(map.land.applying(t), with: .color(Self.land))
                ctx.fill(map.lakes.applying(t), with: .color(Self.ocean))
                ctx.stroke(map.states.applying(t), with: .color(.white.opacity(0.07)), lineWidth: 0.6)
                ctx.stroke(map.borders.applying(t), with: .color(.white.opacity(0.17)), lineWidth: 0.8)
            }
            drawGrid(&ctx, cam, size, vis)
            drawMe(&ctx, cam, size)
            drawMarkers(&ctx, cam, size, markers)
        }
    }

    /// Maidenhead field lines, and square lines with labels once they're far enough apart.
    private func drawGrid(_ ctx: inout GraphicsContext, _ cam: MapCamera, _ size: CGSize,
                          _ vis: (lon: ClosedRange<Double>, lat: ClosedRange<Double>)) {
        let squares = cam.xScale * 2 >= 26
        let stepLon = squares ? 2.0 : 20.0, stepLat = squares ? 1.0 : 10.0
        var lines = Path()
        var l = (vis.lon.lowerBound / stepLon).rounded(.down) * stepLon
        while l <= vis.lon.upperBound {
            let x = cam.point(lon: l, lat: 0, in: size).x
            lines.move(to: CGPoint(x: x, y: 0))
            lines.addLine(to: CGPoint(x: x, y: size.height))
            l += stepLon
        }
        var t = max(-90, (vis.lat.lowerBound / stepLat).rounded(.down) * stepLat)
        while t <= min(90, vis.lat.upperBound) {
            let y = cam.point(lon: cam.lon, lat: t, in: size).y
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
            t += stepLat
        }
        ctx.stroke(lines, with: .color(Theme.accent.opacity(0.09)), lineWidth: 0.6)

        // Labels at each cell's top-left corner, when there's room for them.
        let cellWidth = cam.xScale * stepLon
        guard cellWidth >= (squares ? 46 : 34), cam.scale * stepLat >= 22 else { return }
        var lon = (vis.lon.lowerBound / stepLon).rounded(.down) * stepLon
        while lon <= vis.lon.upperBound {
            var lat = max(-90, (vis.lat.lowerBound / stepLat).rounded(.down) * stepLat)
            while lat < min(90, vis.lat.upperBound) {
                let wrapped = lon - 360 * ((lon + 180) / 360).rounded(.down)
                let name = GridMath.grid(latitude: lat + stepLat / 2, longitude: wrapped + stepLon / 2)
                let p = cam.point(lon: lon, lat: lat + stepLat, in: size)
                ctx.draw(Text(String(name.prefix(squares ? 4 : 2)))
                            .font(Theme.mono(9, .semibold))
                            .foregroundStyle(Theme.accent.opacity(0.28)),
                         at: CGPoint(x: p.x + 3, y: p.y + 2), anchor: .topLeading)
                lat += stepLat
            }
            lon += stepLon
        }
    }

    private func drawMe(_ ctx: inout GraphicsContext, _ cam: MapCamera, _ size: CGSize) {
        guard let sq = GridMath.square(myGrid) else { return }
        let a = cam.point(lon: sq.lon, lat: sq.lat + sq.height, in: size)
        let b = cam.point(lon: sq.lon + sq.width, lat: sq.lat, in: size)
        let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if b.x - a.x >= 8 {
            let r = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            ctx.fill(Path(r), with: .color(Theme.warn.opacity(0.12)))
            ctx.stroke(Path(r), with: .color(Theme.warn.opacity(0.7)), lineWidth: 1)
        }
        var diamond = Path()
        diamond.move(to: CGPoint(x: c.x, y: c.y - 6))
        diamond.addLine(to: CGPoint(x: c.x + 6, y: c.y))
        diamond.addLine(to: CGPoint(x: c.x, y: c.y + 6))
        diamond.addLine(to: CGPoint(x: c.x - 6, y: c.y))
        diamond.closeSubpath()
        ctx.fill(diamond, with: .color(Theme.warn))
        ctx.stroke(diamond, with: .color(Theme.bg), lineWidth: 1)
    }

    private func drawMarkers(_ ctx: inout GraphicsContext, _ cam: MapCamera, _ size: CGSize, _ markers: [MapMarker]) {
        let now = AppClock.now()
        let selected = model.selectedCallsign
        var taken: [CGRect] = []
        if let sq = GridMath.square(myGrid) {
            let me = cam.point(lon: sq.lon + sq.width / 2, lat: sq.lat + sq.height / 2, in: size)
            taken.append(CGRect(x: me.x - 7, y: me.y - 7, width: 14, height: 14))
        }
        var labels: [(MapMarker, CGPoint)] = []

        for m in markers {
            let p = cam.point(lon: m.lon, lat: m.lat, in: size)
            guard p.x > -20, p.x < size.width + 20, p.y > -20, p.y < size.height + 20 else { continue }
            let color = Self.ageColor(now.timeIntervalSince(m.latest))
            let many = m.calls.count > 1
            let r: CGFloat = many ? 8 : 5.5
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r - 4, y: p.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)),
                     with: .color(color.opacity(0.18)))
            ctx.fill(dot, with: .color(color))
            if let watch = m.calls.lazy.compactMap({ model.settings.watch(matching: $0.call) }).first {
                ctx.stroke(dot, with: .color(watch.color.color), lineWidth: 2)
            }
            if m.calls.contains(where: { $0.call == selected }) || m.id == picked {
                let ring = Path(ellipseIn: CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6))
                ctx.stroke(ring, with: .color(m.id == picked ? Theme.text : Theme.accent), lineWidth: 1.6)
            }
            if many {
                ctx.draw(Text("\(m.calls.count)").font(Theme.mono(9, .bold)).foregroundStyle(Theme.bg), at: p)
            }
            taken.append(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            labels.append((m, p))
        }

        // Callsign labels, picked and selected first then freshest, skipping any that would overlap.
        let order = labels.sorted { a, b in
            let pa = a.0.id == picked || a.0.calls.contains { $0.call == selected }
            let pb = b.0.id == picked || b.0.calls.contains { $0.call == selected }
            return pa != pb ? pa : a.0.latest > b.0.latest
        }
        var placed: [CGRect] = []
        for (m, p) in order {
            let name = m.calls.count > 1 ? "\(m.calls[0].call) +\(m.calls.count - 1)" : m.calls[0].call
            let text = ctx.resolve(Text(name).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.text))
            let s = text.measure(in: CGSize(width: 200, height: 40))
            let r: CGFloat = m.calls.count > 1 ? 8 : 5.5
            // Right of the dot, else left, below or above: wherever it fits on the map without overlapping.
            let w = s.width, h = s.height
            let spots = [CGRect(x: p.x + r + 4, y: p.y - h / 2, width: w, height: h),
                         CGRect(x: p.x - r - 4 - w, y: p.y - h / 2, width: w, height: h),
                         CGRect(x: p.x - w / 2, y: p.y + r + 3, width: w, height: h),
                         CGRect(x: p.x - w / 2, y: p.y - r - 3 - h, width: w, height: h)]
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 2)
            guard let rect = spots.first(where: { rect in
                bounds.contains(rect)
                    && !placed.contains { $0.insetBy(dx: -2, dy: -1).intersects(rect) }
                    && !taken.contains { $0.intersects(rect) }
            }) else { continue }
            placed.append(rect)
            var bg = ctx
            bg.opacity = 0.7
            bg.fill(Path(roundedRect: rect.insetBy(dx: -3, dy: -1), cornerRadius: 4), with: .color(Theme.bg))
            ctx.draw(text, in: rect)
        }
    }

    // MARK: Interaction

    /// Pan and pinch together; each update applies only the change since the last one.
    private func panAndZoom(_ markers: [MapMarker], in size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 3)
            .onChanged { v in
                let last = lastDrag ?? .zero
                move(markers, in: size) {
                    $0.pan(by: CGSize(width: v.translation.width - last.width,
                                      height: v.translation.height - last.height), in: size)
                }
                lastDrag = v.translation
            }
            .onEnded { _ in lastDrag = nil }
        let zoom = MagnifyGesture()
            .onChanged { v in
                let last = lastZoom ?? 1
                move(markers, in: size) { $0.zoom(by: v.magnification / last, at: v.startLocation, in: size) }
                lastZoom = v.magnification
            }
            .onEnded { _ in lastZoom = nil }
        return drag.simultaneously(with: zoom)
    }

    /// The camera the user left, kept inside the current view size, or one framing every station.
    private func currentCamera(_ markers: [MapMarker], in size: CGSize) -> MapCamera? {
        guard var cam = camera else { return fitted(markers, in: size) }
        cam.clamp(in: size)
        return cam
    }

    private func move(_ markers: [MapMarker], in size: CGSize, _ change: (inout MapCamera) -> Void) {
        guard var cam = currentCamera(markers, in: size) else { return }
        change(&cam)
        camera = cam
    }

    private func pick(at location: CGPoint, in markers: [MapMarker], _ cam: MapCamera?, _ size: CGSize) {
        guard let cam else { return }
        let hit = markers
            .map { ($0, hypot(cam.point(lon: $0.lon, lat: $0.lat, in: size).x - location.x,
                              cam.point(lon: $0.lon, lat: $0.lat, in: size).y - location.y)) }
            .filter { $0.1 < 24 }
            .min { $0.1 < $1.1 }?.0
        withAnimation(.snappy) { picked = hit?.id }
    }

    /// Frame every station and our own square.
    private func fitted(_ markers: [MapMarker], in size: CGSize) -> MapCamera? {
        guard size.width > 0, size.height > 0 else { return nil }
        let me = GridMath.square(myGrid).map { (lon: $0.lon + $0.width / 2, lat: $0.lat + $0.height / 2) }
        var points = markers.map { (lon: $0.lon, lat: $0.lat) }
        if let me { points.append(me) }
        guard let ref = me ?? points.first else {
            let aspect = cos(Double.pi / 6)
            var cam = MapCamera(lon: 0, lat: 20, scale: 0, aspect: aspect)
            cam.clamp(in: size)
            return cam
        }
        // Unwrap longitudes around our own so a Pacific spread doesn't span the whole world.
        let lons = points.map { $0.lon + 360 * ((ref.lon - $0.lon) / 360).rounded() }
        let lats = points.map(\.lat)
        let minLon = lons.min()!, maxLon = lons.max()!, minLat = lats.min()!, maxLat = lats.max()!
        let midLat = (minLat + maxLat) / 2
        let aspect = max(0.3, cos(midLat * .pi / 180))
        let spanLon = max(maxLon - minLon, 14), spanLat = max(maxLat - minLat, 8)
        // Leave more room on the right, where callsign labels go.
        let left = 30.0, right = 90.0
        let scale = max(0.3, min((size.width - left - right) / (spanLon * aspect), (size.height - 70) / spanLat))
        let shift = (right - left) / 2 / (scale * aspect)
        var cam = MapCamera(lon: (minLon + maxLon) / 2 + shift, lat: midLat, scale: scale, aspect: aspect)
        cam.clamp(in: size)
        return cam
    }

    // MARK: Chrome

    private func controls(_ markers: [MapMarker], in size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return VStack(spacing: 6) {
            mapButton("plus", "Zoom in") { move(markers, in: size) { $0.zoom(by: 2, at: center, in: size) } }
            mapButton("minus", "Zoom out") { move(markers, in: size) { $0.zoom(by: 0.5, at: center, in: size) } }
            mapButton("scope", "Show all stations") { camera = nil }
        }
    }

    private func mapButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.card.opacity(0.92)))
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .accessibilityLabel(label)
    }

    private func summary(_ markers: [MapMarker]) -> some View {
        let onMap = markers.reduce(0) { $0 + $1.calls.count }
        let missing = withoutGrid
        return HStack(spacing: 10) {
            if model.calls.isEmpty {
                Text("Stations appear here when they send a grid.")
            } else {
                Text("\(onMap) on map")
                if !missing.isEmpty {
                    Menu {
                        Section("Ask for a grid") {
                            ForEach(missing.prefix(30)) { cd in
                                Button("\(cd.call) GRID?") {
                                    model.selectedCallsign = cd.call
                                    model.send("GRID?")
                                }
                            }
                        }
                    } label: {
                        Label("\(missing.count) without grid", systemImage: "questionmark.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                }
            }
            Spacer()
            if !model.calls.isEmpty { legend }
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.dim)
        .lineLimit(1)
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach([("15m", Theme.rx), ("1h", Theme.accent), ("older", Theme.dim)], id: \.0) { name, color in
                HStack(spacing: 3) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(name)
                }
            }
        }
        .foregroundStyle(Theme.faint)
        .accessibilityHidden(true)
    }

    private func pickedPanel(_ m: MapMarker) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.id).font(Theme.mono(12, .bold)).foregroundStyle(Theme.text)
                if let db = GridMath.distanceBearing(from: myGrid, to: m.id) {
                    Text("\(Int(db.km)) km  \(Int(db.bearing))°").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button { withAnimation(.snappy) { picked = nil } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(m.calls) { cd in StationListRow(cd: cd, onSelect: onSelect) }
                }
            }
            .frame(maxHeight: m.calls.count > 2 ? 150 : nil)
            .fixedSize(horizontal: false, vertical: m.calls.count <= 2)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Style

    static let ocean = Color(red: 0.045, green: 0.06, blue: 0.10)
    static let land = Color(red: 0.11, green: 0.145, blue: 0.22)

    static func ageColor(_ age: TimeInterval) -> Color {
        switch age {
        case ..<(15 * 60): return Theme.rx
        case ..<(60 * 60): return Theme.accent
        default: return Theme.dim
        }
    }
}
