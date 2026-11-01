import Foundation
import StorageCore

// Headless checks for the parts that keep the app safe. Run with `swift run SafetyChecks`.
// The guard checks only look at paths; the vault checks work inside a throwaway temp folder.

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)")
    }
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let safety = SafetyGuard(isRunning: { _ in false })

func allowed(_ path: String, _ context: RemovalContext = .general) -> Bool {
    safety.check(URL(fileURLWithPath: path), context: context).isAllowed
}

print("Safety guard — must block")
let mustBlock = [
    "/", "/System/Library/CoreServices", "/usr/bin/ls", "/bin", "/Library/Caches/com.example",
    "/private/var/db", "/Users/Shared/file.txt", "/Volumes/External/file.mov",
    home, "\(home)/Documents", "\(home)/Library", "\(home)/Library/Caches", "\(home)/Downloads",
    "\(home)/Library/Keychains/login.keychain-db", "\(home)/library/keychains/login.keychain-db",
    "\(home)/Library/Preferences/com.example.app.plist", "\(home)/Library/Application Support/Foo",
    "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Report.pdf", "\(home)/Library/Mail/V10",
    "\(home)/Library/Caches/com.apple.Safari", "\(home)/Library/Caches/CloudKit",
    "\(home)/Library/Application Support/StorageManager/Vault",
    "\(home)/.ssh/id_ed25519", "\(home)/.zshrc", "\(home)/.config/gh/hosts.yml", "\(home)/.Trash",
    "\(home)/Pictures/Photos Library.photoslibrary",
    "\(home)/Pictures/Photos Library.photoslibrary/originals/A/IMG_0001.HEIC",
    "\(home)/Projects/app/.git/objects/pack/pack-1.pack", "\(home)/Projects/app/.git",
    "\(home)/Documents/../Library/Keychains/login.keychain-db",
    "/Applications/Safari.app", "/Applications/Utilities", "/Applications/Foo.app/Contents/MacOS/Foo",
    "\(home)/Library/Containers/com.example.app",
]
for path in mustBlock { expect(!allowed(path), "blocks \(path)") }

print("Safety guard — may allow")
let mayAllow = [
    "\(home)/Documents/old-report.pdf", "\(home)/Downloads/installer.dmg", "\(home)/Desktop/Screenshot.png",
    "\(home)/Library/Caches/com.google.Chrome", "\(home)/Library/Caches/Homebrew",
    "\(home)/Library/Logs/DiagnosticReports", "\(home)/Library/Developer/Xcode/DerivedData",
    "\(home)/Library/Application Support/MobileSync/Backup/00008030-ABC",
    "\(home)/Projects/web/node_modules", "\(home)/.npm/_cacache", "\(home)/.gradle/caches",
    "\(home)/.Trash/old.zip",
]
for path in mayAllow { expect(allowed(path), "allows \(path)") }

print("Safety guard — app leftovers are exact matches only")
let leftover = RemovalContext.appLeftover(bundleID: "com.example.Editor", appName: "Editor")
expect(allowed("\(home)/Library/Preferences/com.example.Editor.plist", leftover), "allows the app's own preferences")
expect(allowed("\(home)/Library/Application Support/Editor", leftover), "allows the app's own support folder")
expect(allowed("\(home)/Library/Containers/com.example.Editor", leftover), "allows the app's own container")
expect(!allowed("\(home)/Library/Preferences/com.other.App.plist", leftover), "blocks another app's preferences")
expect(!allowed("\(home)/Library/Application Support/Editor/../Other", leftover), "blocks path traversal")
expect(!allowed("\(home)/Library/Keychains/Editor", leftover), "blocks keychains even with a matching name")
let appleLeftover = RemovalContext.appLeftover(bundleID: "com.apple.Notes", appName: "Notes")
expect(!allowed("\(home)/Library/Containers/com.apple.Notes", appleLeftover), "blocks Apple app data")

print("Safety guard — symlinks cannot smuggle paths")
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sm-checks-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let homeTemp = SafetyGuard(home: temp, isRunning: { _ in false })
let outside = temp.deletingLastPathComponent()
try! FileManager.default.createSymbolicLink(at: temp.appendingPathComponent("escape"), withDestinationURL: outside)
expect(!homeTemp.check(temp.appendingPathComponent("escape/something")).isAllowed,
       "blocks a path that leaves home through a symlinked folder")

print("Safety vault")
let vaultBase = temp.appendingPathComponent("support")
let vault = SafetyVault(base: vaultBase, check: { _, _ in .allowed })
let file = temp.appendingPathComponent("docs/notes.txt")
try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
try! "hello".write(to: file, atomically: true, encoding: .utf8)

let entry = try! vault.store(file, size: 5, reason: "test")
expect(!FileManager.default.fileExists(atPath: file.path), "store moves the file out of place")
expect(FileManager.default.fileExists(atPath: entry.storedPath), "the file is held in the vault")
expect(vault.heldBytes == 5, "held size is tracked")

try! FileManager.default.removeItem(at: file.deletingLastPathComponent())
let restored = try! vault.restore(entry.id)
expect(restored.path == file.path, "restore recreates the original folder and location")
expect((try? String(contentsOf: file)) == "hello", "restored contents are intact")

let second = try! vault.store(file, size: 5, reason: "test")
try! "new".write(to: file, atomically: true, encoding: .utf8)
let renamed = try! vault.restore(second.id)
expect(renamed.lastPathComponent == "notes (restored).txt", "restore never overwrites a newer file")
expect((try? String(contentsOf: file)) == "new", "the newer file is untouched")

let third = try! vault.store(renamed, size: 5, reason: "test")
try! vault.purge(third.id)
expect(!FileManager.default.fileExists(atPath: third.storedPath), "purge deletes only after an explicit request")

let reopened = SafetyVault(base: vaultBase, check: { _, _ in .allowed })
expect(reopened.entries.count == 3, "the journal survives a relaunch")

let fourth = try! vault.store(file, size: 3, reason: "test")
try! FileManager.default.removeItem(at: vaultBase.appendingPathComponent("vault-journal.json"))
let rebuilt = SafetyVault(base: vaultBase, check: { _, _ in .allowed })
expect(rebuilt.held.contains { $0.id == fourth.id }, "held items are recovered from manifests if the journal is lost")

let guarded = SafetyVault(base: vaultBase, check: { url, ctx in safety.check(url, context: ctx) })
expect((try? guarded.store(URL(fileURLWithPath: "/usr/bin/true"), size: 0, reason: "test")) == nil,
       "the vault refuses anything the guard blocks")

print(failures == 0 ? "\nAll safety checks passed." : "\n\(failures) safety check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
