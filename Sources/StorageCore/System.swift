import CryptoKit
import Darwin
import Foundation

public struct DiskInfo {
    public let name: String
    public let total: Int64
    /// Truly free right now.
    public let free: Int64
    /// Free plus space macOS can reclaim on its own (purgeable caches, local snapshots).
    public let availableForImportantUsage: Int64

    public var used: Int64 { total - free }
    public var purgeable: Int64 { max(availableForImportantUsage - free, 0) }

    public static func current() -> DiskInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey,
        ]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacity else { return nil }
        return DiskInfo(name: v.volumeLocalizedName ?? "Macintosh HD", total: Int64(total), free: Int64(free),
                        availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage ?? Int64(free))
    }

    /// Number of Time Machine local snapshots — a common, invisible cause of "System Data" growth.
    public static func localSnapshotCount() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }
}

public enum TrashManager {
    public static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Emptying the Trash is the one permanent action the app offers, and only on an explicit request.
    /// Without Full Disk Access macOS hides ~/.Trash from apps, so it falls back to asking Finder.
    public static func empty() -> Result<String, Error> {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil) {
            var removed = 0
            var failures = 0
            for item in items {
                if (try? fm.removeItem(at: item)) != nil { removed += 1 } else { failures += 1 }
            }
            let note = failures > 0 ? " \(failures) item(s) could not be removed." : ""
            return .success("Emptied \(removed) item(s) from the Trash.\(note)")
        }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Finder refused the request."
            return .failure(NSError(domain: "StorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        return .success("Finder emptied the Trash.")
    }
}

public enum ContentHasher {
    public enum Outcome {
        case hash(String)
        /// iCloud placeholder — hashing would download it, so it is skipped.
        case cloudOnly
        case unreadable
    }

    public static func sha256(_ url: URL) -> Outcome {
        var st = stat()
        let dataless: UInt32 = 0x4000_0000 // SF_DATALESS
        if lstat(url.path, &st) == 0, st.st_flags & dataless != 0 { return .cloudOnly }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return .unreadable
        }
        return .hash(hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

public struct ScanSnapshot: Codable {
    public let date: Date
    public let used: Int64
    public let categories: [String: Int64]

    public init(date: Date, used: Int64, categories: [String: Int64]) {
        self.date = date
        self.used = used
        self.categories = categories
    }
}

/// Keeps a short history of scans so the app can show what grew since last time.
public final class HistoryStore {
    private let url: URL
    public private(set) var snapshots: [ScanSnapshot] = []

    public init(base: URL = SafetyVault.defaultBase) {
        url = base.appendingPathComponent("scan-history.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let s = try? decoder.decode([ScanSnapshot].self, from: data) {
            snapshots = s
        }
    }

    public func append(_ snapshot: ScanSnapshot) {
        snapshots = Array((snapshots + [snapshot]).suffix(60))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(snapshots).write(to: url, options: .atomic)
    }
}
