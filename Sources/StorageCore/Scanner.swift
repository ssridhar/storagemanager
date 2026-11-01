import Darwin
import Foundation

public struct ScanResult {
    public let date: Date
    public let homePath: String
    public var categorySizes: [StorageCategory: Int64]
    /// Sizes of the top-level items in the expanded folders (Downloads, ~/Library/Caches, apps…).
    public var entries: [String: FileEntry]
    public var largeFiles: [FileEntry]
    public var duplicateGroups: [DuplicateGroup]
    public var nodeModules: [FileEntry]
    public var installers: [FileEntry]
    /// Folders macOS would not let us read (usually needs Full Disk Access).
    public var unreadable: [String]
    public var filesScanned: Int

    public var measuredTotal: Int64 { categorySizes.values.reduce(0, +) }

    public func children(of dir: String) -> [FileEntry] {
        entries.values.filter { $0.parent == dir }
    }
}

public final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var rootsDone = 0
    private var rootsTotal = 0

    public init() {}

    public var snapshot: (files: Int, done: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        return (files, rootsDone, rootsTotal)
    }

    func addFiles(_ n: Int) { lock.lock(); files += n; lock.unlock() }
    func rootDone() { lock.lock(); rootsDone += 1; lock.unlock() }
    func setTotal(_ n: Int) { lock.lock(); rootsTotal = n; lock.unlock() }
}

/// Read-only walk of the home folder and /Applications. It never modifies anything.
///
/// The top levels are split into independent "roots" that are walked in parallel; each root
/// lands in one category, except node_modules folders which are re-attributed to Developer.
public struct StorageScanner {
    public static let largeFileThreshold: Int64 = 100 * 1_048_576
    public static let duplicateMinSize: Int64 = 1_048_576
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    static let developerDotFolders: Set<String> = [
        ".npm", ".gradle", ".m2", ".cargo", ".rustup", ".docker", ".nvm", ".pyenv", ".conda",
        ".yarn", ".pub-cache", ".android", ".cocoapods", ".swiftpm", ".vscode", ".bun", ".deno",
    ]

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .fileSizeKey, .contentModificationDateKey,
    ]
    static let keySet = Set(keys)

    public let homePath: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Folders whose children are measured individually, so the app can offer them item by item.
    var expandedDirs: Set<String> {
        let h = homePath
        return [
            h, h + "/Library", h + "/Library/Caches", h + "/Library/Logs", h + "/Library/Application Support",
            h + "/Library/Application Support/MobileSync", h + "/Library/Application Support/MobileSync/Backup",
            h + "/Library/Developer", h + "/Library/Developer/Xcode", h + "/Library/Developer/CoreSimulator",
            h + "/Downloads", "/Applications",
        ]
    }

    private final class Partial {
        let root: String
        let category: StorageCategory
        var total: Int64 = 0
        var files = 0
        var nodeModulesSize: Int64 = 0
        var nodeModules: [FileEntry] = []
        var large: [FileEntry] = []
        var installers: [FileEntry] = []
        var dupCandidates: [(entry: FileEntry, logical: Int64)] = []
        var unreadable = false

        init(root: String, category: StorageCategory) {
            self.root = root
            self.category = category
        }
    }

    public func scan(progress: ScanProgress) -> ScanResult {
        let fm = FileManager.default
        let expand = expandedDirs
        var roots: [String] = []
        var rootDates: [String: Date] = [:]
        var unreadable: [String] = []

        var queue = [homePath, "/Applications"]
        while let dir = queue.popLast() {
            let dateKeys: [URLResourceKey] = [.contentModificationDateKey, .addedToDirectoryDateKey]
            guard let kids = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir, isDirectory: true),
                                                         includingPropertiesForKeys: dateKeys) else {
                if fm.fileExists(atPath: dir) { unreadable.append(dir) }
                continue
            }
            for kid in kids {
                let path = kid.path
                if expand.contains(path) { queue.append(path); continue }
                roots.append(path)
                let v = try? kid.resourceValues(forKeys: Set(dateKeys))
                if let d = [v?.contentModificationDate, v?.addedToDirectoryDate].compactMap({ $0 }).max() {
                    rootDates[path] = d
                }
            }
        }

        progress.setTotal(roots.count)
        var partials = [Partial?](repeating: nil, count: roots.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            let partial = walk(roots[i], progress: progress)
            lock.lock(); partials[i] = partial; lock.unlock()
            progress.rootDone()
        }

        var categories: [StorageCategory: Int64] = [:]
        var entries: [String: FileEntry] = [:]
        var large: [FileEntry] = [], nodeModules: [FileEntry] = [], installers: [FileEntry] = []
        var dupMap: [String: [FileEntry]] = [:]
        var files = 0
        for case let p? in partials {
            categories[p.category, default: 0] += p.total - p.nodeModulesSize
            if p.nodeModulesSize > 0 { categories[.developer, default: 0] += p.nodeModulesSize }
            entries[p.root] = FileEntry(path: p.root, size: p.total, modified: rootDates[p.root])
            large += p.large
            nodeModules += p.nodeModules
            installers += p.installers
            files += p.files
            for c in p.dupCandidates {
                dupMap["\(c.entry.name.lowercased())|\(c.logical)", default: []].append(c.entry)
            }
            if p.unreadable { unreadable.append(p.root) }
        }

        return ScanResult(
            date: Date(), homePath: homePath, categorySizes: categories, entries: entries,
            largeFiles: Array(large.sorted { $0.size > $1.size }.prefix(500)),
            duplicateGroups: Self.duplicateGroups(from: dupMap),
            nodeModules: nodeModules.sorted { $0.size > $1.size },
            installers: installers.sorted { $0.size > $1.size },
            unreadable: unreadable.sorted(), filesScanned: files)
    }

    private func walk(_ path: String, progress: ScanProgress) -> Partial {
        let p = Partial(root: path, category: category(for: path))
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: Self.keySet), v.isSymbolicLink != true else { return p }
        if v.isDirectory != true {
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            p.total = size
            p.files = 1
            consider(path, v, size, p)
            return p
        }

        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Self.keys, options: [],
            errorHandler: { failed, _ in
                if failed.standardizedFileURL.path == url.standardizedFileURL.path { p.unreadable = true }
                return true
            })
        guard let enumerator else { p.unreadable = true; return p }

        var nmRoot: String?
        var nmSize: Int64 = 0
        var nmDate: Date?
        var pending = 0
        func closeNodeModules() {
            if let root = nmRoot {
                p.nodeModules.append(FileEntry(path: root, size: nmSize, modified: nmDate))
                p.nodeModulesSize += nmSize
            }
            nmRoot = nil
            nmSize = 0
        }

        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: Self.keySet), rv.isSymbolicLink != true else { continue }
            let fp = fileURL.path
            if let root = nmRoot, !fp.hasPrefix(root + "/") { closeNodeModules() }
            if rv.isDirectory == true {
                if nmRoot == nil, fileURL.lastPathComponent == "node_modules", isActionable(fp) {
                    nmRoot = fp
                    nmDate = rv.contentModificationDate
                }
                continue
            }
            let size = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
            p.total += size
            p.files += 1
            pending += 1
            if pending >= 2000 { progress.addFiles(pending); pending = 0 }
            if nmRoot != nil { nmSize += size; continue }
            consider(fp, rv, size, p)
        }
        closeNodeModules()
        progress.addFiles(pending)
        return p
    }

    private func consider(_ path: String, _ rv: URLResourceValues, _ size: Int64, _ p: Partial) {
        guard size >= Self.duplicateMinSize else { return }
        let entry = FileEntry(path: path, size: size, modified: rv.contentModificationDate)
        if size >= Self.largeFileThreshold, path.hasPrefix(homePath + "/"), !Self.isInsidePackage(path) {
            p.large.append(entry)
        }
        guard isActionable(path) else { return }
        if Self.installerExtensions.contains((path as NSString).pathExtension.lowercased()) {
            p.installers.append(entry)
        }
        p.dupCandidates.append((entry, Int64(rv.fileSize ?? 0)))
    }

    /// Plain user files: in home, outside ~/Library, not hidden, not inside a bundle or node_modules.
    func isActionable(_ path: String) -> Bool {
        guard path.hasPrefix(homePath + "/"), !path.hasPrefix(homePath + "/Library/") else { return false }
        let comps = path.dropFirst(homePath.count + 1).split(separator: "/")
        if comps.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) { return false }
        return !Self.isInsidePackage(path)
    }

    static func isInsidePackage(_ path: String) -> Bool {
        let comps = path.split(separator: "/").dropLast()
        return comps.contains { SafetyGuard.packageExtensions.contains((String($0) as NSString).pathExtension.lowercased()) }
    }

    func category(for path: String) -> StorageCategory {
        if path.hasPrefix("/Applications/") { return .applications }
        guard path.hasPrefix(homePath + "/") else { return .otherUser }
        let comps = path.dropFirst(homePath.count + 1).split(separator: "/").map(String.init)
        guard let first = comps.first else { return .otherUser }
        let second = comps.count > 1 ? comps[1] : ""
        let third = comps.count > 2 ? comps[2] : ""
        switch first {
        case "Desktop": return .desktop
        case "Documents": return .documents
        case "Downloads": return .downloads
        case "Pictures": return .pictures
        case "Music": return .music
        case "Movies": return .movies
        case "Applications": return .applications
        case ".Trash": return .trash
        case "Library":
            switch second {
            case "Caches", "Logs": return .caches
            case "Developer": return .developer
            case "Mail", "Messages": return .mail
            case "Mobile Documents", "CloudStorage": return .iCloud
            case "Containers": return third == "com.apple.mail" ? .mail : .appData
            case "Application Support":
                if third == "StorageManager" { return .vault }
                if third == "MobileSync" { return .deviceBackups }
                return .appData
            default: return .appData
            }
        default:
            if Self.developerDotFolders.contains(first) { return .developer }
            return .otherUser
        }
    }

    static func duplicateGroups(from map: [String: [FileEntry]]) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        for (key, files) in map where files.count > 1 {
            // Hard links point at the same data; removing one frees nothing.
            var seen = Set<String>()
            let unique = files.filter { seen.insert(inodeKey($0.path) ?? $0.path).inserted }
            guard unique.count > 1 else { continue }
            let sorted = unique.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
            let logical = Int64(key.split(separator: "|").last.flatMap { Int64($0) } ?? 0)
            groups.append(DuplicateGroup(id: key, name: sorted[0].name, logicalSize: logical, files: sorted))
        }
        return Array(groups.sorted { $0.reclaimable > $1.reclaimable }.prefix(1000))
    }

    static func inodeKey(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }
}

public enum DirectorySizer {
    public static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            guard let rv = try? f.resourceValues(forKeys: keys), rv.isDirectory != true else { continue }
            total += Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
        }
        return total
    }
}
