import Foundation

/// The buckets the overview ring is split into.
public enum StorageCategory: String, CaseIterable, Codable, Identifiable {
    case system, applications, documents, downloads, desktop, pictures, music, movies
    case developer, caches, mail, iCloud, appData, deviceBackups, trash, vault, otherUser

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "macOS & System Data"
        case .applications: return "Applications"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        case .pictures: return "Photos & Pictures"
        case .music: return "Music"
        case .movies: return "Movies"
        case .developer: return "Developer"
        case .caches: return "Caches & Logs"
        case .mail: return "Mail & Messages"
        case .iCloud: return "iCloud Drive (on this Mac)"
        case .appData: return "App Data"
        case .deviceBackups: return "iPhone & iPad Backups"
        case .trash: return "Trash"
        case .vault: return "Safety Vault"
        case .otherUser: return "Other Files"
        }
    }

    public var symbol: String {
        switch self {
        case .system: return "gearshape.2"
        case .applications: return "square.grid.2x2"
        case .documents: return "doc.text"
        case .downloads: return "arrow.down.circle"
        case .desktop: return "menubar.dock.rectangle"
        case .pictures: return "photo.on.rectangle"
        case .music: return "music.note"
        case .movies: return "film"
        case .developer: return "hammer"
        case .caches: return "archivebox"
        case .mail: return "envelope"
        case .iCloud: return "icloud"
        case .appData: return "shippingbox"
        case .deviceBackups: return "iphone"
        case .trash: return "trash"
        case .vault: return "lock.shield"
        case .otherUser: return "folder"
        }
    }

    public var explanation: String {
        switch self {
        case .system: return "macOS itself, swap, Time Machine local snapshots, other user accounts and anything this app is not allowed to read."
        case .applications: return "Apps in /Applications and ~/Applications."
        case .developer: return "Xcode data, simulators, node_modules folders and package-manager caches."
        case .caches: return "Data apps keep to run faster. Apps rebuild it when needed."
        case .appData: return "Settings, databases and containers that apps keep in ~/Library."
        case .vault: return "Items you removed with Storage Manager, kept so they can be restored."
        case .iCloud: return "Downloaded copies of iCloud Drive files."
        default: return ""
        }
    }
}

public struct FileEntry: Identifiable, Hashable {
    public let path: String
    /// Bytes actually allocated on disk (what removing it would free).
    public let size: Int64
    public let modified: Date?

    public init(path: String, size: Int64, modified: Date?) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
    public var parent: String { (path as NSString).deletingLastPathComponent }
}

public struct DuplicateGroup: Identifiable {
    /// "name|logical size" — files that share both are treated as likely copies.
    public let id: String
    public let name: String
    public let logicalSize: Int64
    /// Sorted oldest first; the oldest copy is the default one to keep.
    public var files: [FileEntry]

    public var reclaimable: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

public func abbreviateHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
