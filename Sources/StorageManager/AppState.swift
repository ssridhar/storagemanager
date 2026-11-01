import AppKit
import StorageCore
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, cleanup, largeFiles, duplicates, apps, vault, safety

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .cleanup: return "Clean Up"
        case .largeFiles: return "Large Files"
        case .duplicates: return "Duplicates"
        case .apps: return "Apps"
        case .vault: return "Safety Vault"
        case .safety: return "Safety Rules"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "internaldrive"
        case .cleanup: return "sparkles"
        case .largeFiles: return "doc.richtext"
        case .duplicates: return "square.on.square"
        case .apps: return "square.grid.2x2"
        case .vault: return "lock.shield"
        case .safety: return "checkmark.shield"
        }
    }
}

struct RemovalRequest: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var context: RemovalContext = .general
    var id: String { url.path }

    static func == (a: RemovalRequest, b: RemovalRequest) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct BlockedItem: Identifiable {
    let request: RemovalRequest
    let reason: String
    var id: String { request.id }
}

struct PendingAction: Identifiable {
    enum Kind {
        case moveToVault(allowed: [RemovalRequest], blocked: [BlockedItem], warnings: [String: String], reason: String)
        case emptyTrash(size: Int64?)
        case purge([VaultEntry])
    }

    let id = UUID()
    let title: String
    let kind: Kind
}

struct ActionReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum VerifyState {
    case verifying, identical, different, cloudOnly, failed
}

@MainActor
final class AppState: ObservableObject {
    @Published var section: SidebarItem? = .overview
    @Published var disk: DiskInfo? = DiskInfo.current()
    @Published var result: ScanResult?
    @Published var suggestions: [CleanupSuggestion] = []
    @Published var apps: [AppInfo] = []
    @Published var isScanning = false
    @Published var scanFiles = 0
    @Published var scanFraction = 0.0
    @Published var previousSnapshot: ScanSnapshot?
    @Published var localSnapshots: Int?
    @Published var removed = Set<String>()
    @Published var vaultEntries: [VaultEntry] = []
    @Published var pending: PendingAction?
    @Published var report: ActionReport?

    // Per-view selections live here so they survive switching sections.
    @Published var cleanupSelection: [String: Set<String>] = [:]
    @Published var duplicateSelection: [String: Set<String>] = [:]
    @Published var verification: [String: VerifyState] = [:]

    let safety = SafetyGuard()
    let vault: SafetyVault
    private let history = HistoryStore()

    init() {
        let safety = self.safety
        vault = SafetyVault(check: { url, context in safety.check(url, context: context) })
        vault.purgeExpired()
        vaultEntries = vault.entries
        previousSnapshot = history.snapshots.last
    }

    // MARK: - Scanning

    var categoryBreakdown: [(category: StorageCategory, size: Int64)] {
        guard let result else { return [] }
        var sizes = result.categorySizes
        if let disk { sizes[.system] = max(disk.used - result.measuredTotal, 0) }
        return sizes.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.size > $1.size }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanFiles = 0
        scanFraction = 0
        let progress = ScanProgress()
        let safety = self.safety

        Task.detached(priority: .userInitiated) {
            let result = StorageScanner().scan(progress: progress)
            let suggestions = SuggestionBuilder.build(from: result, guard: safety)
            let apps = AppInventory.load(entrySizes: result.entries)
            let snapshots = DiskInfo.localSnapshotCount()
            await MainActor.run { self.finishScan(result, suggestions, apps, snapshots) }
        }
        Task {
            while isScanning {
                let s = progress.snapshot
                scanFiles = s.files
                scanFraction = s.total > 0 ? Double(s.done) / Double(s.total) : 0
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func finishScan(_ result: ScanResult, _ suggestions: [CleanupSuggestion], _ apps: [AppInfo], _ snapshots: Int?) {
        disk = DiskInfo.current()
        self.result = result
        self.suggestions = suggestions
        self.apps = apps
        localSnapshots = snapshots
        removed = []
        scanFiles = result.filesScanned
        isScanning = false

        cleanupSelection = Dictionary(uniqueKeysWithValues: suggestions.map {
            ($0.id, $0.safety == .safe ? Set($0.items.map(\.path)) : [])
        })
        duplicateSelection = Dictionary(uniqueKeysWithValues: result.duplicateGroups.map {
            ($0.id, Set($0.files.dropFirst().map(\.path)))
        })
        verification = [:]

        previousSnapshot = history.snapshots.last
        let categories = Dictionary(uniqueKeysWithValues: categoryBreakdown.map { ($0.category.rawValue, $0.size) })
        history.append(ScanSnapshot(date: result.date, used: disk?.used ?? 0, categories: categories))
    }

    func delta(for category: StorageCategory, current: Int64) -> Int64? {
        guard let previous = previousSnapshot?.categories[category.rawValue] else { return nil }
        return current - previous
    }

    // MARK: - Removal (always into the Safety Vault)

    func requestRemoval(_ requests: [RemovalRequest], title: String, reason: String) {
        var allowed: [RemovalRequest] = []
        var blocked: [BlockedItem] = []
        var warnings: [String: String] = [:]
        for request in Set(requests) {
            if let why = safety.check(request.url, context: request.context).reason {
                blocked.append(BlockedItem(request: request, reason: why))
            } else {
                allowed.append(request)
                if let warning = safety.warning(for: request.url) { warnings[request.id] = warning }
            }
        }
        guard !allowed.isEmpty || !blocked.isEmpty else { return }
        pending = PendingAction(title: title, kind: .moveToVault(
            allowed: allowed.sorted { $0.size > $1.size }, blocked: blocked, warnings: warnings, reason: reason))
    }

    func requestEmptyTrash() {
        pending = PendingAction(title: "Empty the Trash?", kind: .emptyTrash(size: trashSize))
    }

    func requestPurge(_ entries: [VaultEntry]) {
        guard !entries.isEmpty else { return }
        pending = PendingAction(title: entries.count == 1 ? "Delete permanently?" : "Delete \(entries.count) items permanently?",
                                kind: .purge(entries))
    }

    func perform(_ action: PendingAction) {
        pending = nil
        switch action.kind {
        case .moveToVault(let allowed, let blocked, _, let reason):
            var moved: [String] = []
            var bytes: Int64 = 0
            var failures: [String] = blocked.map { "\($0.request.url.lastPathComponent): \($0.reason)" }
            // Parents first, so children of an already-moved folder are simply skipped.
            for request in allowed.sorted(by: { $0.id.count < $1.id.count }) {
                if moved.contains(where: { request.id.hasPrefix($0 + "/") }) { continue }
                do {
                    try vault.store(request.url, size: request.size, reason: reason, context: request.context)
                    moved.append(request.id)
                    bytes += request.size
                } catch {
                    failures.append("\(request.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            removed.formUnion(moved)
            vaultEntries = vault.entries
            var message = "Moved \(moved.count) item(s), \(formatBytes(bytes)), to the Safety Vault. "
                + "They can be restored for \(vault.retentionDays) days; delete them from the vault to free the space now."
            if !failures.isEmpty {
                message += "\n\nNot moved:\n" + failures.prefix(8).joined(separator: "\n")
                if failures.count > 8 { message += "\n…and \(failures.count - 8) more" }
            }
            report = ActionReport(title: "Moved to Safety Vault", message: message)

        case .emptyTrash:
            switch TrashManager.empty() {
            case .success(let message): report = ActionReport(title: "Trash emptied", message: message)
            case .failure(let error): report = ActionReport(title: "Could not empty the Trash", message: error.localizedDescription)
            }
            if let path = result?.homePath { result?.entries[path + "/.Trash"] = nil }
            disk = DiskInfo.current()

        case .purge(let entries):
            var freed: Int64 = 0
            for entry in entries where (try? vault.purge(entry.id)) != nil { freed += entry.size }
            vaultEntries = vault.entries
            disk = DiskInfo.current()
            report = ActionReport(title: "Deleted permanently", message: "Freed \(formatBytes(freed)).")
        }
    }

    func restore(_ entry: VaultEntry) {
        do {
            let url = try vault.restore(entry.id)
            removed.remove(entry.originalPath)
            report = ActionReport(title: "Restored", message: "\(entry.name) is back at \(abbreviateHome(url.path)).")
        } catch {
            report = ActionReport(title: "Could not restore \(entry.name)", message: error.localizedDescription)
        }
        vaultEntries = vault.entries
    }

    func setRetention(_ days: Int) {
        vault.retentionDays = days
        objectWillChange.send()
    }

    // MARK: - Apps

    func requestAppRemoval(_ selected: [AppInfo], includeLeftovers: Bool) {
        Task.detached(priority: .userInitiated) {
            var requests: [RemovalRequest] = []
            for app in selected {
                requests.append(RemovalRequest(url: app.url, size: app.size))
                if includeLeftovers {
                    let context = RemovalContext.appLeftover(bundleID: app.bundleID,
                                                             appName: app.url.deletingPathExtension().lastPathComponent)
                    requests += AppInventory.leftovers(for: app).map { RemovalRequest(url: $0.url, size: $0.size, context: context) }
                }
            }
            let all = requests
            await MainActor.run {
                self.requestRemoval(all, title: "Remove \(selected.count) app(s)?", reason: "Unused app")
            }
        }
    }

    // MARK: - Duplicates

    func verify(_ group: DuplicateGroup) {
        verification[group.id] = .verifying
        Task.detached(priority: .utility) {
            var hashes = Set<String>()
            var state = VerifyState.identical
            for file in group.files {
                switch ContentHasher.sha256(file.url) {
                case .hash(let h): hashes.insert(h)
                case .cloudOnly: state = .cloudOnly
                case .unreadable: state = .failed
                }
                if state != .identical { break }
            }
            if state == .identical && hashes.count > 1 { state = .different }
            let outcome = state
            await MainActor.run { self.applyVerification(outcome, to: group.id) }
        }
    }

    private func applyVerification(_ outcome: VerifyState, to groupID: String) {
        verification[groupID] = outcome
        // Never offer to remove files that turned out to differ.
        if outcome == .different { duplicateSelection[groupID] = [] }
    }

    // MARK: - Helpers

    var trashSize: Int64? {
        guard let result else { return nil }
        return result.entries[result.homePath + "/.Trash"]?.size
    }

    var safeReclaimable: Int64 {
        suggestions.filter { $0.safety == .safe }.reduce(0) { total, s in
            total + s.items.filter { !removed.contains($0.path) }.reduce(0) { $0 + $1.size }
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
