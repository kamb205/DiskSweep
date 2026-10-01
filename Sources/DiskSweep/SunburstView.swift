import SwiftUI

/// A sunburst chart of folder sizes: the centre is the current folder, the first ring its
/// subfolders, and outer rings their subfolders. Hover to see a slice; click it to open it,
/// click the centre to go up a level.
struct SunburstView: View {
    @EnvironmentObject var model: AppModel
    let folder: String
    let root: String

    private let ringCount = 3

    struct Segment: Identifiable {
        let path: String
        let size: Int64
        let depth: Int
        let start: Double
        let end: Double
        let colorIndex: Int
        var id: String { path }
    }

    @State private var hovered: Segment?
    /// The slice the context menu acts on: the last one hovered, kept while the menu is open.
    @State private var menuTarget: Segment?

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .yellow, .green, .teal, .indigo, .mint, .red]

    private var segments: [Segment] {
        guard let sizes = model.result?.folderSizes, let total = sizes[folder], total > 0 else { return [] }
        var out: [Segment] = []
        func add(_ parent: String, depth: Int, start: Double, span: Double, parentSize: Int64, colorIndex: Int?) {
            guard depth <= ringCount, parentSize > 0 else { return }
            var cursor = start
            let kids = (model.children[parent] ?? []).map { ($0, sizes[$0] ?? 0) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            for (index, (path, size)) in kids.enumerated() {
                let fraction = Double(size) / Double(parentSize) * span
                guard fraction >= 0.004 else { break }
                let color = colorIndex ?? index
                out.append(Segment(path: path, size: size, depth: depth, start: cursor, end: cursor + fraction, colorIndex: color))
                add(path, depth: depth + 1, start: cursor, span: fraction, parentSize: size, colorIndex: color)
                cursor += fraction
            }
        }
        add(folder, depth: 1, start: 0, span: 1, parentSize: total, colorIndex: nil)
        return out
    }

    var body: some View {
        let segments = segments
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ringWidth = side / 2 / CGFloat(ringCount + 1)
            ZStack {
                Canvas { context, _ in
                    for segment in segments {
                        let inner = ringWidth * CGFloat(segment.depth)
                        let outer = inner + ringWidth - 2
                        var path = Path()
                        path.addArc(center: center, radius: outer, startAngle: angle(segment.start), endAngle: angle(segment.end), clockwise: false)
                        path.addArc(center: center, radius: inner, startAngle: angle(segment.end), endAngle: angle(segment.start), clockwise: true)
                        path.closeSubpath()
                        let base = Self.palette[segment.colorIndex % Self.palette.count]
                        let isHovered = hovered?.path == segment.path
                        let isSelected = model.selection.contains(segment.path)
                        let opacity = isHovered ? 1.0 : [0.95, 0.72, 0.5][min(segment.depth - 1, 2)]
                        context.fill(path, with: .color(isSelected ? .red.opacity(isHovered ? 1 : 0.85) : base.opacity(opacity)))
                        context.stroke(path, with: .color(isSelected ? .white : .black.opacity(0.25)), lineWidth: isSelected ? 2 : 1)
                    }
                    let hole = Path(ellipseIn: CGRect(x: center.x - ringWidth + 2, y: center.y - ringWidth + 2,
                                                      width: (ringWidth - 2) * 2, height: (ringWidth - 2) * 2))
                    context.fill(hole, with: .color(.secondary.opacity(0.15)))
                }

                VStack(spacing: 2) {
                    Text(hovered.map { ($0.path as NSString).lastPathComponent } ?? displayName(folder))
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(Fmt.bytes(hovered?.size ?? model.result?.folderSizes[folder] ?? 0))
                        .font(.title3.bold())
                        .monospacedDigit()
                    if let hovered, model.selection.contains(hovered.path) {
                        Text("Ticked for Trash").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    } else if hovered != nil {
                        Text("Right-click for options").font(.caption2).foregroundStyle(.secondary)
                    } else if folder != root {
                        Text("Click to go up").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: ringWidth * 1.7)
                .position(center)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    hovered = segment(at: point, center: center, ringWidth: ringWidth, in: segments)
                    menuTarget = hovered
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                let distance = hypot(tap.location.x - center.x, tap.location.y - center.y)
                if distance < ringWidth {
                    if folder != root { model.openFolder((folder as NSString).deletingLastPathComponent) }
                } else if let hit = segment(at: tap.location, center: center, ringWidth: ringWidth, in: segments) {
                    if NSEvent.modifierFlags.contains(.option) {
                        // Option-click ticks or unticks a slice for the Trash.
                        model.spaceLensBinding(for: hit.path).wrappedValue.toggle()
                    } else if !(model.children[hit.path] ?? []).isEmpty {
                        hovered = nil
                        model.openFolder(hit.path)
                    }
                }
            })
            .contextMenu {
                if let target = menuTarget {
                    let name = (target.path as NSString).lastPathComponent
                    Text("\(name) · \(Fmt.bytes(target.size))")
                    if !(model.children[target.path] ?? []).isEmpty {
                        Button("Open") { model.openFolder(target.path) }
                    }
                    if model.canSelectInSpaceLens(target.path) {
                        Button(model.selection.contains(target.path) ? "Untick" : "Tick for Trash") {
                            model.spaceLensBinding(for: target.path).wrappedValue.toggle()
                        }
                    } else {
                        Text("Protected by macOS")
                    }
                    Button("Show in Finder") { model.reveal([target.path]) }
                } else {
                    Button("Show in Finder") { model.reveal([folder]) }
                }
            }
        }
    }

    private func angle(_ fraction: Double) -> Angle { .degrees(fraction * 360 - 90) }

    private func displayName(_ path: String) -> String {
        path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent
    }

    private func segment(at point: CGPoint, center: CGPoint, ringWidth: CGFloat, in segments: [Segment]) -> Segment? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let depth = Int(hypot(dx, dy) / ringWidth)
        guard depth >= 1, depth <= ringCount else { return nil }
        var degrees = atan2(dy, dx) * 180 / .pi + 90
        if degrees < 0 { degrees += 360 }
        let fraction = degrees / 360
        return segments.first { $0.depth == depth && fraction >= $0.start && fraction < $0.end }
    }
}
