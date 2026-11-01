import StorageCore
import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection = Set<String>()
    @State private var unusedOnly = true
    @State private var includeLeftovers = true

    private var rows: [AppInfo] {
        state.apps.filter { !state.removed.contains($0.path) && (!unusedOnly || $0.isUnused(days: 90)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("App") { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.name)
                            Text(app.version.isEmpty ? app.bundleID : "\(app.version) · \(app.bundleID)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                TableColumn("Size") { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                TableColumn("Last opened") { app in
                    Text(app.lastUsed?.formatted(.relative(presentation: .named)) ?? "Never / unknown")
                        .foregroundStyle(app.isUnused(days: 90) ? .orange : .secondary)
                }
                .width(140)
                TableColumn("Source") { app in
                    Text(app.fromAppStore ? "App Store" : "Downloaded").foregroundStyle(.secondary)
                }
                .width(100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Show in Finder") { ids.forEach { state.reveal($0) } }
            }
            HStack {
                Toggle("Also remove the app's support files and settings", isOn: $includeLeftovers)
                    .help("Matched exactly by the app's bundle ID or name in ~/Library. Shown for review before anything moves.")
                Spacer()
                Button("Move to Safety Vault…") {
                    state.requestAppRemoval(rows.filter { selection.contains($0.path) }, includeLeftovers: includeLeftovers)
                    selection = []
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Toggle("Unused 90+ days", isOn: $unusedOnly).toggleStyle(.switch)
            }
        }
        .navigationTitle("Apps")
        .navigationSubtitle("Third-party apps only — Apple apps are part of macOS. App Store apps can be re-downloaded for free.")
    }
}

struct VaultView: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""

    private var held: [VaultEntry] {
        state.vaultEntries.filter { $0.state == .held && (query.isEmpty || $0.originalPath.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.removedAt > $1.removedAt }
    }

    private var history: [VaultEntry] {
        state.vaultEntries.filter { $0.state != .held }
            .sorted { ($0.stateChangedAt ?? $0.removedAt) > ($1.stateChangedAt ?? $1.removedAt) }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 34)).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(formatBytes(state.vault.heldBytes)) held in \(held.count) item(s)").font(.title3.weight(.semibold))
                        Text("Everything Storage Manager removes waits here before it is deleted. Restore puts it back exactly where it was "
                             + "(renamed if something new is in its place). Items are deleted automatically after the retention period.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Picker("Keep items for", selection: Binding(
                                get: { state.vault.retentionDays }, set: { state.setRetention($0) })) {
                                ForEach([3, 7, 14, 30, 60], id: \.self) { Text("\($0) days").tag($0) }
                            }
                            .frame(width: 220)
                            Spacer()
                            Button("Delete All Now…", role: .destructive) { state.requestPurge(held) }
                                .disabled(held.isEmpty)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Held items") {
                if held.isEmpty {
                    Text("Nothing in the vault.").foregroundStyle(.secondary)
                }
                ForEach(held) { entry in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.storedPath)).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1)
                            Text("from \(abbreviateHome((entry.originalPath as NSString).deletingLastPathComponent)) · \(entry.reason)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(formatBytes(entry.size)).monospacedDigit()
                            Text("deletes \(state.vault.expiry(of: entry).formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Restore") { state.restore(entry) }.buttonStyle(.borderedProminent)
                        Button("Delete…", role: .destructive) { state.requestPurge([entry]) }
                    }
                    .padding(.vertical, 3)
                }
            }

            if !history.isEmpty {
                Section("History") {
                    ForEach(history.prefix(200)) { entry in
                        HStack {
                            Image(systemName: icon(for: entry.state)).foregroundStyle(.secondary).frame(width: 20)
                            Text(entry.name).lineLimit(1)
                            Text(label(for: entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(formatBytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Find a removed item")
        .navigationTitle("Safety Vault")
    }

    private func icon(for state: VaultEntry.State) -> String {
        switch state {
        case .restored: return "arrow.uturn.backward.circle"
        case .purged: return "xmark.bin"
        case .missing: return "questionmark.folder"
        case .held: return "lock"
        }
    }

    private func label(for entry: VaultEntry) -> String {
        let when = (entry.stateChangedAt ?? entry.removedAt).formatted(date: .abbreviated, time: .shortened)
        switch entry.state {
        case .restored: return "restored \(when) to \(abbreviateHome(entry.restoredTo ?? entry.originalPath))"
        case .purged: return "deleted \(when)"
        case .missing: return "no longer in the vault (removed outside the app)"
        case .held: return ""
        }
    }
}

struct SafetyRulesView: View {
    @EnvironmentObject private var state: AppState
    @State private var testPath = ""

    private let rules: [(String, String)] = [
        ("internaldrive", "Only your user folder and whole third-party apps in /Applications can ever be touched. /System, /Library, /usr, other users and external drives are off-limits."),
        ("lock.shield", "Nothing is deleted directly. Items move to the Safety Vault and can be restored until the retention period ends."),
        ("key", "Keychains, Mail, Messages, Safari, Calendars, accounts, iCloud Drive and other personal or system state in ~/Library are always refused."),
        ("folder.badge.gearshape", "Standard folders (Desktop, Documents, Library…) can be cleaned inside but never removed themselves."),
        ("shippingbox", "Bundles are never picked apart: nothing inside an app, Photos library or Music library can be removed, and those libraries can't be removed whole."),
        ("terminal", "Hidden settings (.ssh, .zshrc, .config, .aws…) and Git history are refused; only known package caches (.npm, .gradle, .m2, .cargo) are allowed."),
        ("apple.logo", "Apple apps, Apple system caches, running apps and Storage Manager itself are refused."),
        ("square.on.square", "At least one copy of every duplicate set is always kept; verified-different files are deselected."),
        ("icloud", "iCloud placeholders are never downloaded to compare them, and removals in synced folders show a warning."),
        ("link", "Symlinks are resolved before checking, so a link can't redirect a removal outside the allowed areas. Paths are compared case-insensitively."),
    ]

    var body: some View {
        Form {
            Section("How Storage Manager keeps your Mac safe") {
                ForEach(rules, id: \.1) { symbol, text in
                    Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: symbol).foregroundStyle(.teal)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Check a path") {
                TextField("Paste or type a path, e.g. ~/Library/Keychains", text: $testPath)
                    .textFieldStyle(.roundedBorder)
                if !testPath.isEmpty {
                    let expanded = (testPath as NSString).expandingTildeInPath
                    let verdict = state.safety.check(URL(fileURLWithPath: expanded))
                    Label(verdict.reason ?? "Allowed — would be moved to the Safety Vault, not deleted",
                          systemImage: verdict.isAllowed ? "checkmark.circle.fill" : "hand.raised.fill")
                        .foregroundStyle(verdict.isAllowed ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Safety Rules")
    }
}

struct ConfirmSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let action: PendingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.title).font(.title2.bold())
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { state.pending = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                confirmButton
            }
        }
        .padding(22)
        .frame(width: 620)
        .frame(minHeight: 260)
    }

    @ViewBuilder private var content: some View {
        switch action.kind {
        case .moveToVault(let allowed, let blocked, let warnings, _):
            Text("\(allowed.count) item(s), \(formatBytes(allowed.reduce(0) { $0 + $1.size })), will move to the Safety Vault. "
                 + "You can restore them for \(state.vault.retentionDays) days.")
                .foregroundStyle(.secondary)
            List {
                if !allowed.isEmpty {
                    Section("Will be moved") {
                        ForEach(allowed) { request in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(request.url.lastPathComponent).lineLimit(1)
                                    Text(abbreviateHome(request.url.deletingLastPathComponent().path))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(formatBytes(request.size)).monospacedDigit()
                                }
                                if let warning = warnings[request.id] {
                                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                if !blocked.isEmpty {
                    Section("Protected — will not be touched") {
                        ForEach(blocked) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(item.request.url.lastPathComponent, systemImage: "lock.fill")
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)

        case .emptyTrash(let size):
            Label("This permanently deletes everything in the Trash\(size.map { " (\(formatBytes($0)))" } ?? ""). It cannot be undone.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Items removed with Storage Manager are not in the Trash — they stay in the Safety Vault and are unaffected.")
                .foregroundStyle(.secondary)

        case .purge(let entries):
            Label("\(entries.count) item(s), \(formatBytes(entries.reduce(0) { $0 + $1.size })), will be deleted permanently. They can no longer be restored.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var confirmButton: some View {
        switch action.kind {
        case .moveToVault(let allowed, _, _, _):
            Button("Move to Safety Vault") { state.perform(action); dismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(allowed.isEmpty)
        case .emptyTrash:
            Button("Empty Trash", role: .destructive) { state.perform(action); dismiss() }
        case .purge:
            Button("Delete Permanently", role: .destructive) { state.perform(action); dismiss() }
        }
    }
}
