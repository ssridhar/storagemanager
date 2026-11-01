import CoreServices
import Foundation

public struct AppInfo: Identifiable, Hashable {
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String
    public let size: Int64
    public let lastUsed: Date?
    public let fromAppStore: Bool

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    public func isUnused(days: Int, now: Date = Date()) -> Bool {
        guard let lastUsed else { return true }
        return lastUsed < now.addingTimeInterval(-Double(days) * 86_400)
    }
}

public enum AppInventory {
    /// Third-party apps only — Apple apps are part of macOS and are not listed.
    public static func load(entrySizes: [String: FileEntry],
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AppInfo] {
        let fm = FileManager.default
        var bundles: [URL] = []
        for dir in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                if item.pathExtension == "app" {
                    bundles.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level of folders, e.g. /Applications/Adobe Photoshop/…app
                    let nested = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    bundles += nested.filter { $0.pathExtension == "app" }
                }
            }
        }

        return bundles.compactMap { url -> AppInfo? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !id.lowercased().hasPrefix("com.apple.") else { return nil }
            let info = bundle.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let size = entrySizes[url.path]?.size ?? DirectorySizer.size(of: url)
            return AppInfo(
                path: url.path, name: name, bundleID: id,
                version: (info["CFBundleShortVersionString"] as? String) ?? "",
                size: size, lastUsed: lastUsedDate(url),
                fromAppStore: fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path))
        }
        .sorted { $0.size > $1.size }
    }

    /// Spotlight records when an app was last opened; nil means never (or Spotlight is off).
    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Support files an app leaves in ~/Library, matched exactly by bundle ID or app name.
    public static func leftovers(for app: AppInfo,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [FileEntry] {
        let lib = home.appendingPathComponent("Library").path
        let b = app.bundleID
        let n = app.url.deletingPathExtension().lastPathComponent
        let candidates = [
            "\(lib)/Application Support/\(b)", "\(lib)/Application Support/\(n)", "\(lib)/Caches/\(b)",
            "\(lib)/Preferences/\(b).plist", "\(lib)/Containers/\(b)", "\(lib)/Saved Application State/\(b).savedState",
            "\(lib)/HTTPStorages/\(b)", "\(lib)/WebKit/\(b)", "\(lib)/Logs/\(n)", "\(lib)/Logs/\(b)",
        ]
        var seen = Set<String>()
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0.lowercased()).inserted }
            .map { FileEntry(path: $0, size: DirectorySizer.size(of: URL(fileURLWithPath: $0)), modified: nil) }
    }
}
