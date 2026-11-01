import StorageCore
import SwiftUI

extension StorageCategory {
    var color: Color {
        switch self {
        case .system: return Color(white: 0.55)
        case .applications: return .blue
        case .documents: return .orange
        case .downloads: return .teal
        case .desktop: return .indigo
        case .pictures: return .pink
        case .music: return .red
        case .movies: return .purple
        case .developer: return .green
        case .caches: return .yellow
        case .mail: return .cyan
        case .iCloud: return .mint
        case .appData: return .brown
        case .deviceBackups: return Color(red: 0.35, green: 0.45, blue: 0.75)
        case .trash: return Color(white: 0.4)
        case .vault: return Color(red: 0.2, green: 0.6, blue: 0.5)
        case .otherUser: return Color(white: 0.7)
        }
    }
}

struct RingSegment: Identifiable {
    let id: String
    let label: String
    let value: Int64
    let color: Color
}

/// A donut drawn like a disk platter: one arc per category, free space as the unfilled track.
struct DiskRing: View {
    let segments: [RingSegment]
    let total: Int64
    @Binding var hovered: String?
    let title: String
    let subtitle: String

    var diameter: CGFloat = 300

    var body: some View {
        let side = diameter
        let thickness = side * 0.17
        ZStack {
            Circle().fill(Color.secondary.opacity(0.08))
            Circle().inset(by: thickness / 2).stroke(Color.secondary.opacity(0.15), lineWidth: thickness)
            ForEach(arcs) { arc in
                RingArc(start: arc.start, end: arc.end, thickness: thickness)
                    .fill(arc.segment.color)
                    .opacity(hovered == nil || hovered == arc.segment.id ? 1 : 0.3)
                    .contentShape(RingArc(start: arc.start, end: arc.end, thickness: thickness))
                    .onHover { inside in
                        if inside { hovered = arc.segment.id } else if hovered == arc.segment.id { hovered = nil }
                    }
                    .help("\(arc.segment.label): \(formatBytes(arc.segment.value))")
            }
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .padding(thickness + side * 0.04)
            VStack(spacing: 4) {
                if let id = hovered, let seg = segments.first(where: { $0.id == id }) {
                    Text(formatBytes(seg.value)).font(.system(size: side * 0.09, weight: .semibold, design: .rounded))
                    Text(seg.label).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Text(title).font(.system(size: side * 0.09, weight: .semibold, design: .rounded))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(width: side * 0.5)
        }
        .frame(width: side, height: side)
    }

    private struct Arc: Identifiable {
        let segment: RingSegment
        let start: Angle
        let end: Angle
        var id: String { segment.id }
    }

    private var arcs: [Arc] {
        guard total > 0 else { return [] }
        var cursor = -90.0
        var result: [Arc] = []
        for segment in segments {
            let sweep = Double(segment.value) / Double(total) * 360
            guard sweep > 0.3 else { cursor += sweep; continue }
            result.append(Arc(segment: segment, start: .degrees(cursor + 0.4), end: .degrees(cursor + sweep - 0.4)))
            cursor += sweep
        }
        return result
    }
}

struct RingArc: Shape {
    let start: Angle
    let end: Angle
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: radius - thickness, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct OverviewView: View {
    @EnvironmentObject private var state: AppState
    @State private var hovered: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(alignment: .top, spacing: 32) {
                    DiskRing(segments: segments, total: state.disk?.total ?? 0, hovered: $hovered,
                             title: formatBytes(state.disk?.free ?? 0), subtitle: "available")
                    legend.frame(maxWidth: .infinity)
                }
                cards
                if let unreadable = state.result?.unreadable, !unreadable.isEmpty { accessNote(unreadable) }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }

    private var segments: [RingSegment] {
        guard let disk = state.disk else { return [] }
        if state.result == nil {
            return [RingSegment(id: "used", label: "Used", value: disk.used, color: .accentColor)]
        }
        return state.categoryBreakdown.map {
            RingSegment(id: $0.category.rawValue, label: $0.category.title, value: $0.size, color: $0.category.color)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.disk?.name ?? "Disk").font(.largeTitle.bold())
                if let disk = state.disk {
                    Text("\(formatBytes(disk.used)) used of \(formatBytes(disk.total)) · \(formatBytes(disk.free)) free"
                         + (disk.purgeable > 0 ? " (+ \(formatBytes(disk.purgeable)) purgeable)" : ""))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let disk = state.disk {
                Gauge(value: Double(disk.used), in: 0...Double(max(disk.total, 1))) {
                    Text("Used")
                } currentValueLabel: {
                    Text("\(Int(Double(disk.used) / Double(max(disk.total, 1)) * 100))%")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(Double(disk.free) / Double(max(disk.total, 1)) < 0.1 ? .red : .accentColor)
            }
        }
    }

    @ViewBuilder private var legend: some View {
        if state.result == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("What's using your storage").font(.headline)
                ProgressView(value: state.scanFraction) {
                    Text(state.isScanning ? "Measuring folders… \(state.scanFiles.formatted()) files" : "Not scanned yet")
                        .foregroundStyle(.secondary)
                }
                Text("Scanning only reads file sizes. Nothing is changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let total = max(state.disk?.used ?? 1, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("What's using your storage").font(.headline)
                    Spacer()
                    if let previous = state.previousSnapshot {
                        Text("change since \(previous.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 6)
                ForEach(state.categoryBreakdown, id: \.category) { item in
                    LegendRow(category: item.category, size: item.size, fraction: Double(item.size) / Double(total),
                              delta: state.delta(for: item.category, current: item.size),
                              highlighted: hovered == item.category.rawValue)
                        .onHover { inside in hovered = inside ? item.category.rawValue : nil }
                        .help(item.category.explanation)
                }
            }
        }
    }

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            InfoCard(symbol: "sparkles", tint: .green, title: "Safe to clean",
                     value: state.result == nil ? "—" : formatBytes(state.safeReclaimable),
                     detail: "Caches and build data that rebuild themselves.") {
                Button("Review") { state.section = .cleanup }
            }
            InfoCard(symbol: "square.on.square", tint: .orange, title: "Duplicates",
                     value: formatBytes(state.result?.duplicateGroups.reduce(0) { $0 + $1.reclaimable } ?? 0),
                     detail: "\(state.result?.duplicateGroups.count ?? 0) sets of same-name, same-size files.") {
                Button("Review") { state.section = .duplicates }
            }
            InfoCard(symbol: "square.grid.2x2", tint: .blue, title: "Unused apps",
                     value: formatBytes(state.apps.filter { $0.isUnused(days: 90) }.reduce(0) { $0 + $1.size }),
                     detail: "\(state.apps.filter { $0.isUnused(days: 90) }.count) apps not opened in 90 days.") {
                Button("Review") { state.section = .apps }
            }
            InfoCard(symbol: "trash", tint: .gray, title: "Trash",
                     value: state.trashSize.map(formatBytes) ?? "Unknown",
                     detail: state.trashSize == nil ? "macOS hides the Trash size without Full Disk Access." : "Emptying is permanent.") {
                Button("Empty…") { state.requestEmptyTrash() }
            }
            InfoCard(symbol: "lock.shield", tint: .teal, title: "Safety Vault",
                     value: formatBytes(state.vault.heldBytes),
                     detail: "Removed items you can still restore for \(state.vault.retentionDays) days.") {
                Button("Open") { state.section = .vault }
            }
            InfoCard(symbol: "clock.arrow.circlepath", tint: .purple, title: "Purgeable",
                     value: formatBytes(state.disk?.purgeable ?? 0),
                     detail: state.localSnapshots.map { "Includes \($0) Time Machine local snapshot(s). macOS frees this when needed." }
                         ?? "Space macOS frees on its own when needed.") { EmptyView() }
        }
    }

    private func accessNote(_ unreadable: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.slash").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(unreadable.count) folder(s) could not be measured").font(.headline)
                Text("macOS protects some folders (Mail, Safari, Trash…). Their space is counted under “macOS & System Data”. "
                     + "Grant Full Disk Access for a complete picture — the app still never touches protected data.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(unreadable.prefix(4).map(abbreviateHome).joined(separator: ", ") + (unreadable.count > 4 ? "…" : ""))
                    .font(.caption).foregroundStyle(.tertiary)
                Button("Open Full Disk Access Settings") { state.openFullDiskAccessSettings() }
            }
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LegendRow: View {
    let category: StorageCategory
    let size: Int64
    let fraction: Double
    let delta: Int64?
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: category.symbol).foregroundStyle(category.color).frame(width: 18)
                Text(category.title)
                Spacer()
                if let delta, abs(delta) >= 50_000_000 {
                    Text((delta > 0 ? "+" : "−") + formatBytes(abs(delta)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(delta > 0 ? .red : .green)
                }
                Text(formatBytes(size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            }
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(category.color).frame(width: max(geo.size.width * fraction, 2))
                    }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(highlighted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct InfoCard<Action: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).foregroundStyle(tint)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action().controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}
