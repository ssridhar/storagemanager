import StorageCore
import SwiftUI

struct CleanupView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Clean Up").font(.largeTitle.bold())
                        Text("Everything you remove goes to the Safety Vault first, so it can be restored.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        state.requestRemoval(selectedRequests, title: "Clean up \(selectedRequests.count) item(s)?",
                                             reason: "Clean Up")
                    } label: {
                        Label("Clean Selected (\(formatBytes(selectedRequests.reduce(0) { $0 + $1.size })))",
                              systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selectedRequests.isEmpty)
                }

                if state.result == nil {
                    ProgressView("Scanning…").frame(maxWidth: .infinity).padding(40)
                } else if state.suggestions.isEmpty {
                    Text("Nothing to clean right now.").foregroundStyle(.secondary).padding(40)
                }
                ForEach(state.suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion)
                }
            }
            .padding(24)
        }
        .navigationTitle("Clean Up")
    }

    private var selectedRequests: [RemovalRequest] {
        state.suggestions.flatMap { s in
            s.items.filter { state.cleanupSelection[s.id]?.contains($0.path) == true && !state.removed.contains($0.path) }
                .map { RemovalRequest(url: $0.url, size: $0.size) }
        }
    }
}

struct SuggestionCard: View {
    @EnvironmentObject private var state: AppState
    let suggestion: CleanupSuggestion
    @State private var expanded = false

    private var items: [FileEntry] { suggestion.items.filter { !state.removed.contains($0.path) } }
    private var selection: Set<String> { state.cleanupSelection[suggestion.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: suggestion.symbol).font(.title2).frame(width: 30)
                    .foregroundStyle(suggestion.safety == .safe ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(suggestion.title).font(.headline)
                        SafetyBadge(safety: suggestion.safety)
                    }
                    Text(suggestion.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(formatBytes(items.reduce(0) { $0 + $1.size })).font(.title3.weight(.semibold).monospacedDigit())
                    Text("\(items.count) item(s)").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 0) {
                    HStack {
                        Button("Select All") { state.cleanupSelection[suggestion.id] = Set(items.map(\.path)) }
                        Button("Select None") { state.cleanupSelection[suggestion.id] = [] }
                        Spacer()
                    }
                    .controlSize(.small)
                    .padding(.vertical, 6)
                    ForEach(items.prefix(300)) { item in
                        FileToggleRow(item: item, isOn: Binding(
                            get: { selection.contains(item.path) },
                            set: { on in
                                var s = selection
                                if on { s.insert(item.path) } else { s.remove(item.path) }
                                state.cleanupSelection[suggestion.id] = s
                            }))
                        Divider()
                    }
                }
            } label: {
                Text("\(selection.intersection(items.map(\.path)).count) of \(items.count) selected")
                    .font(.callout)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

struct SafetyBadge: View {
    let safety: CleanupSafety

    var body: some View {
        Text(safety == .safe ? "Safe" : "Review")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((safety == .safe ? Color.green : .orange).opacity(0.15), in: Capsule())
            .foregroundStyle(safety == .safe ? .green : .orange)
    }
}

struct FileToggleRow: View {
    @EnvironmentObject private var state: AppState
    let item: FileEntry
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(abbreviateHome(item.parent)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let date = item.modified {
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Text(formatBytes(item.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button { state.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.vertical, 5)
    }
}
