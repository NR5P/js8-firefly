import SwiftUI
import JS8Core

/// Waterfall with frequency ruler, spectrum trace, decode labels and the
/// operator's transmit passband. Tap or drag to move the offset.
struct WaterfallView: View {
    @Environment(AppModel.self) private var model
    var showSpectrum = true

    private let minHz = WaterfallRenderer.minHz
    private let maxHz = WaterfallRenderer.maxHz

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let rulerH: CGFloat = 18
            ZStack(alignment: .topLeading) {
                Color.black
                if let img = model.waterfallImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: w, height: h - rulerH)
                        .offset(y: rulerH)
                }

                Canvas { ctx, size in
                    // Ruler
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rulerH)), with: .color(Theme.bg2))
                    var f = 500.0
                    while f < maxHz {
                        let x = xFor(f, w)
                        let major = Int(f) % 500 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: rulerH - (major ? 7 : 4)))
                        p.addLine(to: CGPoint(x: x, y: rulerH))
                        ctx.stroke(p, with: .color(Theme.dim), lineWidth: 1)
                        if major {
                            ctx.draw(Text("\(Int(f))").font(Theme.mono(9)).foregroundStyle(Theme.dim),
                                     at: CGPoint(x: x, y: 6), anchor: .center)
                        }
                        f += 100
                    }

                    // Period boundaries (the lines themselves are in the image)
                    let imgH = size.height - rulerH
                    for mark in model.periodMarks {
                        let y = rulerH + CGFloat(mark.rowsFromTop) / CGFloat(WaterfallRenderer.height) * imgH
                        guard y < size.height - 8 else { continue }
                        let label = ctx.resolve(Text(Self.utc.string(from: mark.start))
                            .font(Theme.mono(9)).foregroundStyle(Color.white.opacity(0.85)))
                        let ts = label.measure(in: CGSize(width: 100, height: 20))
                        let rect = CGRect(x: 2, y: y - ts.height - 1, width: ts.width + 6, height: ts.height)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.black.opacity(0.5)))
                        ctx.draw(label, at: CGPoint(x: 5, y: rect.midY), anchor: .leading)
                    }

                    // Spectrum trace
                    if showSpectrum, model.spectrum.count > 2 {
                        var path = Path()
                        let n = model.spectrum.count
                        let baseY = size.height
                        let ampH = (size.height - rulerH) * 0.35
                        for (i, v) in model.spectrum.enumerated() {
                            let x = CGFloat(i) / CGFloat(n - 1) * size.width
                            let y = baseY - CGFloat(max(0, min(1.2, v))) * ampH
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        ctx.stroke(path, with: .color(Color.white.opacity(0.45)), lineWidth: 1)
                    }

                    // Operator passband
                    let off = Double(model.settings.offset)
                    let bw = Double(model.settings.submode.bandwidth)
                    let x0 = xFor(off, w), x1 = xFor(off + bw, w)
                    let band = CGRect(x: x0, y: rulerH, width: max(2, x1 - x0), height: size.height - rulerH)
                    let txColor = model.isTransmitting ? Theme.tx : Theme.warn
                    ctx.fill(Path(band), with: .color(txColor.opacity(0.10)))
                    var edges = Path()
                    edges.move(to: CGPoint(x: x0, y: rulerH)); edges.addLine(to: CGPoint(x: x0, y: size.height))
                    edges.move(to: CGPoint(x: x1, y: rulerH)); edges.addLine(to: CGPoint(x: x1, y: size.height))
                    ctx.stroke(edges, with: .color(txColor.opacity(0.9)), lineWidth: 1.2)
                    var marker = Path()
                    marker.move(to: CGPoint(x: x0, y: 0))
                    marker.addLine(to: CGPoint(x: x1, y: 0))
                    marker.addLine(to: CGPoint(x: x1, y: rulerH - 3))
                    marker.addLine(to: CGPoint(x: x0, y: rulerH - 3))
                    marker.closeSubpath()
                    ctx.fill(marker, with: .color(txColor))

                    // Decode labels
                    let now = Date()
                    var lanes: [CGFloat] = []
                    for m in model.markers.sorted(by: { $0.frequency < $1.frequency }) {
                        let age = now.timeIntervalSince(m.date)
                        let alpha = max(0.15, 1 - age / 45)
                        let mx = xFor(Double(m.frequency), w)
                        let mw = max(2, xFor(Double(m.frequency) + Double(m.bandwidth), w) - mx)
                        var lane = 0
                        while lane < lanes.count && lanes[lane] > mx { lane += 1 }
                        if lane == lanes.count { lanes.append(0) }
                        let label = Text(m.label).font(Theme.mono(10, .semibold)).foregroundStyle(Color.white)
                        let resolved = ctx.resolve(label)
                        let ts = resolved.measure(in: CGSize(width: 200, height: 20))
                        lanes[lane] = mx + ts.width + 10
                        let y = rulerH + 4 + CGFloat(lane) * 16
                        let rect = CGRect(x: mx, y: y, width: ts.width + 8, height: 14)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Theme.modeColor(m.submode).opacity(0.75 * alpha)))
                        ctx.draw(resolved, at: CGPoint(x: mx + 4, y: y + 7), anchor: .leading)
                        ctx.fill(Path(CGRect(x: mx, y: y + 14, width: mw, height: 2)), with: .color(Theme.modeColor(m.submode).opacity(alpha)))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { g in
                        let hz = minHz + Double(g.location.x / w) * (maxHz - minHz)
                        let bw = Double(model.settings.submode.bandwidth)
                        model.setOffset(Int((hz - bw / 2).rounded()))
                    }
            )
            .overlay(alignment: .bottomTrailing) {
                Text("\(model.settings.offset) Hz")
                    .font(Theme.mono(11, .bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .foregroundStyle(Theme.warn)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func xFor(_ hz: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((hz - minHz) / (maxHz - minHz)) * w
    }
}
