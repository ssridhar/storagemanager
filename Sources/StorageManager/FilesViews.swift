import StorageCore
import SwiftUI

struct LargeFilesView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var sortByDate = false

    private var rows: [FileEntry] {
        let files = (state.result?.largeFiles ?? []).filter {
            !state.removed.contains($0.path) && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query))
        }
        return sortByDate
            ? files.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
            : files
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { file in
                    let blocked = state.safety.check(file.url).reason
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 16, height: 16)
                        Text(file.name).lineLimit(1)
                        if let blocked {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Protected: \(blocked)")
                        }
                    }
                }
                TableColumn("Size") { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                TableColumn("Modified") { file in
                    Text(file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary)
                }
                .width(110)
                TableColumn("Location") { file in
                    Text(abbreviateHome(file.parent)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Show in Finder") { ids.forEach { state.reveal($0) } }
            } primaryAction: { ids in
                ids.forEach { state.reveal($0) }
            }
            SelectionBar(selection: selection, files: rows, reason: "Large file") { selection = [] }
        }
        .searchable(text: $query, prompt: "Filter by name or folder")
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sortByDate) {
                    Text("Largest first").tag(false)
                    Text("Oldest first").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Large Files")
        .navigationSubtitle("Files over \(formatBytes(StorageScanner.largeFileThreshold)) in your user folder")
    }
}

/// Footer shared by file tables: shows what is selected and sends it to the vault.
struct SelectionBar: View {
    @EnvironmentObject private var state: AppState
    let selection: Set<String>
    let files: [FileEntry]
    let reason: String
    let onDone: () -> Void

    var body: some View {
        let chosen = files.filter { selection.contains($0.path) }
        HStack {
            Text(chosen.isEmpty ? "Select files to act on them" :
                    "\(chosen.count) selected · \(formatBytes(chosen.reduce(0) { $0 + $1.size }))")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show in Finder") { chosen.forEach { state.reveal($0.path) } }.disabled(chosen.isEmpty)
            Button("Move to Safety Vault…") {
                state.requestRemoval(chosen.map { RemovalRequest(url: $0.url, size: $0.size) },
                                     title: "Move \(chosen.count) item(s) to the Safety Vault?", reason: reason)
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty)
        }
        .padding(12)
        .background(.bar)
    }
}

struct DuplicatesView: View {
    @EnvironmentObject private var state: AppState

    private var groups: [DuplicateGroup] {
        (state.result?.duplicateGroups ?? []).compactMap { group in
            var g = group
            g.files = group.files.filter { !state.removed.contains($0.path) }
            return g.files.count > 1 ? g : nil
        }
    }

    private var requests: [RemovalRequest] {
        groups.flatMap { g in
            g.files.filter { state.duplicateSelection[g.id]?.contains($0.path) == true }
                .map { RemovalRequest(url: $0.url, size: $0.size) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    HStack(alignment: .top) {
                        Text("Files with the same name and size in different folders. The oldest copy is kept by default — "
                             + "at least one copy in every set is always kept. Use Verify to compare contents byte for byte.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Verify All") { groups.prefix(200).forEach { if state.verification[$0.id] == nil { state.verify($0) } } }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(groups) { group in DuplicateGroupRow(group: group) }
            }
            HStack {
                Text("\(requests.count) copies selected · \(formatBytes(requests.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Move Selected Copies to Safety Vault…") {
                    state.requestRemoval(requests, title: "Move \(requests.count) duplicate(s) to the Safety Vault?",
                                         reason: "Duplicate")
                }
                .buttonStyle(.borderedProminent)
                .disabled(requests.isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
        .navigationTitle("Duplicates")
    }
}

struct DuplicateGroupRow: View {
    @EnvironmentObject private var state: AppState
    let group: DuplicateGroup

    private var selection: Set<String> { state.duplicateSelection[group.id] ?? [] }

    var body: some View {
        DisclosureGroup {
            ForEach(group.files) { file in
                let selected = selection.contains(file.path)
                let keptCount = group.files.filter { !selection.contains($0.path) }.count
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { selected },
                        set: { on in
                            var s = selection
                            if on { s.insert(file.path) } else { s.remove(file.path) }
                            state.duplicateSelection[group.id] = s
                        }))
                        .labelsHidden().toggleStyle(.checkbox)
                        .disabled(!selected && keptCount <= 1) // never allow removing every copy
                    Text(selected ? "Remove" : "Keep")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selected ? .orange : .green)
                        .frame(width: 50, alignment: .leading)
                    Text(abbreviateHome(file.parent)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "").font(.caption)
                        .foregroundStyle(.secondary)
                    Button { state.reveal(file.path) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.files[0].path)).resizable().frame(width: 20, height: 20)
                Text(group.name).lineLimit(1)
                Text("\(group.files.count) copies · \(formatBytes(group.files[0].size)) each")
                    .font(.caption).foregroundStyle(.secondary)
                verifyBadge
                Spacer()
                Text("Reclaim \(formatBytes(group.reclaimable))").monospacedDigit().foregroundStyle(.secondary)
                Button("Verify") { state.verify(group) }
                    .controlSize(.small)
                    .disabled(state.verification[group.id] != nil)
            }
        }
    }

    @ViewBuilder private var verifyBadge: some View {
        switch state.verification[group.id] {
        case .verifying: ProgressView().controlSize(.small)
        case .identical: Label("Identical", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
        case .different: Label("Contents differ", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .cloudOnly: Label("In iCloud only", systemImage: "icloud").font(.caption).foregroundStyle(.secondary)
        case .failed: Label("Couldn't read", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
        case nil: EmptyView()
        }
    }
}
