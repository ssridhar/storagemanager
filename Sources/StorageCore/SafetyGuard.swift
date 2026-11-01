import AppKit
import Foundation

public enum SafetyVerdict: Equatable {
    case allowed
    case blocked(String)

    public var isAllowed: Bool { self == .allowed }
    public var reason: String? {
        if case .blocked(let why) = self { return why }
        return nil
    }
}

/// Why something is being removed. Leftover files of an app get a narrow, exact-match exception
/// to the ~/Library rules; everything else is judged by the general rules.
public enum RemovalContext: Equatable {
    case general
    case appLeftover(bundleID: String, appName: String)
}

/// The single gatekeeper every removal passes through. It is deliberately an allowlist:
/// anything not positively known to be user data or regenerable is refused.
///
/// All comparisons are case-insensitive because the default APFS volume is, so
/// "~/library/keychains" must be caught just like "~/Library/Keychains".
public struct SafetyGuard {
    public let homePath: String
    private let isRunning: (String) -> Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                isRunning: ((String) -> Bool)? = nil) {
        homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        self.isRunning = isRunning ?? { bundleID in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
        }
    }

    // Standard folders that must never be removed as a whole (their contents may be).
    static let protectedHomeFolders: Set<String> = [
        "desktop", "documents", "downloads", "library", "pictures", "movies", "music",
        "public", "applications", "sites", ".trash",
    ]

    // Bundles whose insides must never be picked apart, and libraries that must never be removed whole.
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "photoslibrary", "photolibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "aplibrary",
        "sparsebundle", "migratedphotolibrary",
    ]
    static let wholeLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
        "aplibrary", "migratedphotolibrary",
    ]

    struct Rule {
        let prefix: [String]
        let includeSelf: Bool
    }

    // Hidden folders in home that hold only re-downloadable package caches.
    static let hiddenAllow: [Rule] = [
        Rule(prefix: [".trash"], includeSelf: false),
        Rule(prefix: [".npm", "_cacache"], includeSelf: true),
        Rule(prefix: [".gradle", "caches"], includeSelf: true),
        Rule(prefix: [".m2", "repository"], includeSelf: true),
        Rule(prefix: [".cargo", "registry"], includeSelf: true),
    ]

    // Parts of ~/Library that are regenerable or explicitly user-managed.
    static let libraryAllow: [Rule] = [
        Rule(prefix: ["caches"], includeSelf: false),
        Rule(prefix: ["logs"], includeSelf: false),
        Rule(prefix: ["saved application state"], includeSelf: false),
        Rule(prefix: ["developer", "xcode", "deriveddata"], includeSelf: true),
        Rule(prefix: ["developer", "xcode", "ios devicesupport"], includeSelf: true),
        Rule(prefix: ["developer", "xcode", "watchos devicesupport"], includeSelf: true),
        Rule(prefix: ["developer", "coresimulator", "caches"], includeSelf: true),
        Rule(prefix: ["application support", "mobilesync", "backup"], includeSelf: false),
    ]

    // Always refused inside ~/Library, even for app leftovers.
    static let libraryDeny: [[String]] = [
        ["keychains"], ["mail"], ["messages"], ["mobile documents"], ["cloudstorage"], ["accounts"],
        ["cookies"], ["calendars"], ["safari"], ["launchagents"], ["group containers"], ["photos"],
        ["passes"], ["sharing"], ["suggestions"], ["identityservices"], ["personalizationportrait"],
        ["application support", "storagemanager"], ["application support", "addressbook"],
        ["application support", "com.apple.tcc"], ["application support", "callhistorydb"],
        ["application support", "knowledge"]
    ]

    // Apple caches that are in active use by system daemons.
    static let protectedCacheNames: Set<String> = ["cloudkit", "familycircle", "geoservices", "passkit", "metadata"]

    public static func normalize(_ url: URL) -> String {
        let std = url.standardizedFileURL
        if std.path == "/" { return "/" }
        // Resolve symlinks in the parent so a link can't smuggle a path past the rules,
        // but keep the item itself (removing a symlink removes the link, not its target).
        let parent = std.deletingLastPathComponent().resolvingSymlinksInPath()
        var path = parent.appendingPathComponent(std.lastPathComponent).path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public func check(_ url: URL, context: RemovalContext = .general) -> SafetyVerdict {
        let path = Self.normalize(url)
        let lower = path.lowercased()
        let home = homePath.lowercased()

        if path == "/" || path.isEmpty { return .blocked("The root of your disk") }
        if lower == home { return .blocked("Your home folder") }

        if lower.hasPrefix("/applications/") {
            return checkApplications(path: path)
        }
        guard lower.hasPrefix(home + "/") else {
            return .blocked("Outside your user folder — macOS and other users' files are never touched")
        }

        let comps = lower.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = comps.first else { return .blocked("Your home folder") }

        if comps.count == 1 && Self.protectedHomeFolders.contains(first) {
            return .blocked("A standard macOS folder — its contents can be cleaned, not the folder itself")
        }
        if comps.contains(".git") {
            return .blocked("Part of a Git repository's history")
        }
        if let why = packageProblem(comps) { return .blocked(why) }

        if first == "library" {
            return checkLibrary(Array(comps.dropFirst()), context: context)
        }
        if first.hasPrefix(".") {
            return matches(comps, Self.hiddenAllow)
                ? .allowed
                : .blocked("A hidden settings folder (e.g. SSH keys, shell or tool configuration)")
        }
        if lower.hasSuffix(".app") {
            return checkAppBundle(path: path)
        }
        return .allowed
    }

    /// Non-blocking cautions shown in the confirmation sheet.
    public func warning(for url: URL) -> String? {
        let lower = Self.normalize(url).lowercased()
        guard lower.hasPrefix(homePath.lowercased() + "/") else { return nil }
        let comps = lower.dropFirst(homePath.count + 1).split(separator: "/").map(String.init)
        guard let first = comps.first else { return nil }
        let syncedFolders = ["dropbox", "google drive", "onedrive", "box", "creative cloud files"]
        if syncedFolders.contains(where: { first.hasPrefix($0) }) {
            return "In a cloud-synced folder — removing it here also removes it from the cloud and your other devices."
        }
        if first == "desktop" || first == "documents" {
            let icloudDesktop = homePath + "/Library/Mobile Documents/com~apple~CloudDocs/Desktop"
            if FileManager.default.fileExists(atPath: icloudDesktop) {
                return "Desktop & Documents sync with iCloud — removing it also removes it from your other devices."
            }
        }
        if comps.starts(with: ["library", "application support", "mobilesync"]) {
            return "A device backup. Make sure a newer backup of that iPhone/iPad exists (iCloud or another Mac)."
        }
        return nil
    }

    // MARK: - Rule helpers

    private func matches(_ comps: [String], _ rules: [Rule]) -> Bool {
        rules.contains { rule in
            comps.starts(with: rule.prefix) && (comps.count > rule.prefix.count || rule.includeSelf)
        }
    }

    private func packageProblem(_ comps: [String]) -> String? {
        for (i, comp) in comps.enumerated() {
            let ext = (comp as NSString).pathExtension
            guard Self.packageExtensions.contains(ext) else { continue }
            if i < comps.count - 1 {
                return "Inside an app or library bundle — removing pieces would corrupt it"
            }
            if Self.wholeLibraryExtensions.contains(ext) {
                return "A Photos/Music/iMovie library — manage it from inside that app"
            }
        }
        return nil
    }

    private func checkLibrary(_ sub: [String], context: RemovalContext) -> SafetyVerdict {
        guard !sub.isEmpty else { return .blocked("Your Library folder") }
        if Self.libraryDeny.contains(where: { sub.starts(with: $0) }) {
            return .blocked("Personal data or system state macOS depends on (keychains, mail, iCloud, accounts…)")
        }
        if sub[0] == "caches", sub.count > 1,
           sub[1].hasPrefix("com.apple.") || Self.protectedCacheNames.contains(sub[1]) {
            return .blocked("An Apple system cache — macOS manages these itself")
        }
        if case .appLeftover(let bundleID, let appName) = context,
           isExactLeftover(sub, bundleID: bundleID.lowercased(), appName: appName.lowercased()) {
            return .allowed
        }
        if matches(sub, Self.libraryAllow) { return .allowed }
        return .blocked("Inside ~/Library — settings and data that apps depend on")
    }

    private func isExactLeftover(_ sub: [String], bundleID b: String, appName n: String) -> Bool {
        guard b.count >= 3, n.count >= 3, !b.hasPrefix("com.apple.") else { return false }
        let candidates: [[String]] = [
            ["application support", b], ["application support", n], ["caches", b],
            ["preferences", b + ".plist"], ["containers", b], ["saved application state", b + ".savedstate"],
            ["httpstorages", b], ["webkit", b], ["logs", n], ["logs", b],
        ]
        return candidates.contains(sub)
    }

    private func checkApplications(path: String) -> SafetyVerdict {
        let comps = path.lowercased().split(separator: "/").map(String.init) // ["applications", ...]
        if let why = packageProblem(Array(comps.dropFirst())) { return .blocked(why) }
        guard comps.count <= 3, comps.last?.hasSuffix(".app") == true else {
            return .blocked("Only whole apps can be removed from /Applications")
        }
        return checkAppBundle(path: path)
    }

    private func checkAppBundle(path: String) -> SafetyVerdict {
        guard let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier else {
            return .blocked("Not a valid app bundle")
        }
        if bundleID.lowercased().hasPrefix("com.apple.") {
            return .blocked("An Apple app that is part of macOS")
        }
        if bundleID == Bundle.main.bundleIdentifier {
            return .blocked("Storage Manager itself")
        }
        if isRunning(bundleID) {
            return .blocked("The app is running — quit it first")
        }
        return .allowed
    }
}
