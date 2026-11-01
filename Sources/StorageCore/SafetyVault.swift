import Foundation

public struct VaultEntry: Codable, Identifiable, Hashable {
    public enum State: String, Codable {
        case held, restored, purged, missing
    }

    public let id: UUID
    public let originalPath: String
    public let storedPath: String
    public let size: Int64
    public let removedAt: Date
    public let reason: String
    public var state: State
    public var stateChangedAt: Date?
    public var restoredTo: String?

    public var name: String { (originalPath as NSString).lastPathComponent }
}

public enum VaultError: LocalizedError {
    case blocked(String)
    case missing
    case notHeld

    public var errorDescription: String? {
        switch self {
        case .blocked(let why): return "Protected: \(why)"
        case .missing: return "The item no longer exists"
        case .notHeld: return "The item is not in the Safety Vault"
        }
    }
}

/// Nothing Storage Manager removes is deleted straight away. Items are moved (an instant rename on
/// the same volume) into a vault inside the app's support folder, recorded in a journal, and only
/// permanently deleted once the retention period ends or the user deletes them explicitly.
///
/// Every item also gets its own manifest next to it, so the journal can be rebuilt if it is lost.
public final class SafetyVault {
    public static var defaultBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StorageManager", isDirectory: true)
    }

    private struct Journal: Codable {
        var retentionDays: Int
        var entries: [VaultEntry]
    }

    public let base: URL
    public private(set) var entries: [VaultEntry] = []
    public var retentionDays: Int = 14 {
        didSet { try? save() }
    }

    private let check: (URL, RemovalContext) -> SafetyVerdict
    private let fm = FileManager.default
    private var itemsDir: URL { base.appendingPathComponent("Vault", isDirectory: true) }
    private var journalURL: URL { base.appendingPathComponent("vault-journal.json") }

    public init(base: URL = SafetyVault.defaultBase,
                check: @escaping (URL, RemovalContext) -> SafetyVerdict) {
        self.base = base
        self.check = check
        load()
        reconcile()
    }

    public var held: [VaultEntry] { entries.filter { $0.state == .held } }
    public var heldBytes: Int64 { held.reduce(0) { $0 + $1.size } }

    public func expiry(of entry: VaultEntry) -> Date {
        entry.removedAt.addingTimeInterval(TimeInterval(retentionDays) * 86_400)
    }

    @discardableResult
    public func store(_ url: URL, size: Int64, reason: String,
                      context: RemovalContext = .general) throws -> VaultEntry {
        if case .blocked(let why) = check(url, context) { throw VaultError.blocked(why) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw VaultError.missing }

        let id = UUID()
        let dir = itemsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        let stored = VaultEntry(id: id, originalPath: SafetyGuard.normalize(url), storedPath: dest.path,
                                size: size, removedAt: Date(), reason: reason,
                                state: .held, stateChangedAt: nil, restoredTo: nil)

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try encoder.encode(stored).write(to: dir.appendingPathComponent(".manifest.json"), options: .atomic)
            try fm.moveItem(at: url, to: dest)
        } catch {
            if !fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dir) }
            throw error
        }
        entries.append(stored)
        try? save()
        return stored
    }

    /// Moves an item back where it came from. If something now occupies that path the restored
    /// copy is renamed rather than overwriting it.
    @discardableResult
    public func restore(_ id: UUID) throws -> URL {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].state == .held else {
            throw VaultError.notHeld
        }
        let src = URL(fileURLWithPath: entries[i].storedPath)
        guard fm.fileExists(atPath: src.path) else {
            entries[i].state = .missing
            try? save()
            throw VaultError.missing
        }
        var dest = URL(fileURLWithPath: entries[i].originalPath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { dest = uniqueRestoreURL(for: dest) }
        try fm.moveItem(at: src, to: dest)
        removeItemDir(for: entries[i])

        entries[i].state = .restored
        entries[i].stateChangedAt = Date()
        entries[i].restoredTo = dest.path
        try? save()
        return dest
    }

    /// Permanently deletes one held item. This is the only place the app deletes user files.
    public func purge(_ id: UUID) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].state == .held else {
            throw VaultError.notHeld
        }
        removeItemDir(for: entries[i])
        entries[i].state = .purged
        entries[i].stateChangedAt = Date()
        try? save()
    }

    @discardableResult
    public func purgeExpired(now: Date = Date()) -> Int64 {
        var freed: Int64 = 0
        for entry in held where expiry(of: entry) < now {
            if (try? purge(entry.id)) != nil { freed += entry.size }
        }
        return freed
    }

    /// Marks entries whose files vanished and re-adopts vault items the journal lost track of.
    public func reconcile() {
        var changed = false
        for i in entries.indices where entries[i].state == .held && !fm.fileExists(atPath: entries[i].storedPath) {
            entries[i].state = .missing
            entries[i].stateChangedAt = Date()
            changed = true
        }
        let known = Set(entries.map { $0.id.uuidString })
        let dirs = (try? fm.contentsOfDirectory(atPath: itemsDir.path)) ?? []
        for dir in dirs where !known.contains(dir) {
            let manifest = itemsDir.appendingPathComponent(dir).appendingPathComponent(".manifest.json")
            if let data = try? Data(contentsOf: manifest),
               let entry = try? decoder.decode(VaultEntry.self, from: data),
               fm.fileExists(atPath: entry.storedPath) {
                entries.append(entry)
                changed = true
            }
        }
        if changed { try? save() }
    }

    // MARK: - Persistence

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func load() {
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? decoder.decode(Journal.self, from: data) else { return }
        entries = journal.entries
        retentionDays = journal.retentionDays
    }

    private func save() throws {
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let data = try encoder.encode(Journal(retentionDays: retentionDays, entries: entries))
        try data.write(to: journalURL, options: .atomic)
    }

    private func removeItemDir(for entry: VaultEntry) {
        let dir = URL(fileURLWithPath: entry.storedPath).deletingLastPathComponent()
        // Only ever delete a direct child of the vault folder.
        guard dir.deletingLastPathComponent().standardizedFileURL.path == itemsDir.standardizedFileURL.path,
              dir.lastPathComponent == entry.id.uuidString else { return }
        try? fm.removeItem(at: dir)
    }

    private func uniqueRestoreURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        for n in 1... {
            let suffix = n == 1 ? " (restored)" : " (restored \(n))"
            let candidate = parent.appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
