import Foundation

public enum CleanupSafety: String {
    /// Regenerable data; pre-selected.
    case safe
    /// Your data or slow to get back; nothing is pre-selected.
    case review
}

public struct CleanupSuggestion: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let safety: CleanupSafety
    public let detail: String
    public let items: [FileEntry]

    public var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

public enum SuggestionBuilder {
    public static func build(from r: ScanResult, guard safety: SafetyGuard, now: Date = Date()) -> [CleanupSuggestion] {
        let h = r.homePath
        let day: TimeInterval = 86_400
        var out: [CleanupSuggestion] = []
        var claimed = Set<String>()

        func add(_ id: String, _ title: String, _ symbol: String, _ level: CleanupSafety,
                 _ detail: String, _ items: [FileEntry]) {
            let kept = items
                .filter { $0.size > 0 && !claimed.contains($0.path) && safety.check($0.url).isAllowed }
                .sorted { $0.size > $1.size }
            guard !kept.isEmpty else { return }
            claimed.formUnion(kept.map(\.path))
            out.append(CleanupSuggestion(id: id, title: title, symbol: symbol, safety: level, detail: detail, items: kept))
        }

        add("caches", "App caches", "archivebox", .safe,
            "Temporary data apps keep to load faster. Apps rebuild it automatically; quit them first for the best result. Apple system caches are never included.",
            r.children(of: h + "/Library/Caches").filter { $0.size >= 1_048_576 })

        add("logs", "Old log files", "doc.plaintext", .safe,
            "Diagnostic logs written by apps. Nothing needs them to run.",
            r.children(of: h + "/Library/Logs"))

        let xcode = h + "/Library/Developer/Xcode"
        add("xcode", "Xcode build data", "hammer", .safe,
            "DerivedData, device support files and simulator caches. Xcode recreates them on the next build or device connection.",
            [xcode + "/DerivedData", xcode + "/iOS DeviceSupport", xcode + "/watchOS DeviceSupport",
             h + "/Library/Developer/CoreSimulator/Caches"].compactMap { r.entries[$0] })

        let packageCaches = [".npm/_cacache", ".gradle/caches", ".m2/repository", ".cargo/registry"]
            .map { h + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { FileEntry(path: $0, size: DirectorySizer.size(of: URL(fileURLWithPath: $0)), modified: nil) }
        add("packages", "Package manager caches", "shippingbox", .safe,
            "Downloaded copies of npm, Gradle, Maven and Cargo packages. They are fetched again on the next build.",
            packageCaches)

        add("installers", "Installer files", "opticaldiscdrive", .review,
            "Disk images and installer packages (.dmg, .pkg, .iso, .xip). Once the app is installed these are usually no longer needed.",
            r.installers)

        add("downloads", "Old downloads", "arrow.down.circle", .review,
            "Items in Downloads that were added and last changed more than 90 days ago.",
            r.children(of: h + "/Downloads").filter { ($0.modified ?? now) < now.addingTimeInterval(-90 * day) })

        add("node_modules", "Unused node_modules", "cube.box", .review,
            "Dependency folders in JavaScript projects untouched for 30+ days. Run `npm install` to get them back.",
            r.nodeModules.filter { ($0.modified ?? now) < now.addingTimeInterval(-30 * day) })

        add("backups", "iPhone & iPad backups", "iphone", .review,
            "Local device backups made by Finder. Only remove ones you have a newer copy of.",
            r.children(of: h + "/Library/Application Support/MobileSync/Backup"))

        return out
    }
}
