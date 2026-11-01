# Storage Manager

A lightweight, native macOS app that shows what is filling your Mac's disk and helps you reclaim space, **without ever putting your Mac at risk**.

- **See it:** a disk ring that splits used space into Applications, Documents, Developer, Caches, iCloud, System Data and more, with how much each one changed since your last scan.
- **Clean it:** app caches, logs, Xcode build data, package-manager caches, installer files, old downloads, stale `node_modules` and old iPhone backups.
- **Find it:** large files, duplicate files (same name and size in different folders, with optional byte-for-byte verification) and apps you haven't opened in 90 days, plus their leftover support files.
- **Undo it:** nothing is deleted directly. Everything goes to a **Safety Vault** and can be restored to its exact original location.

> See the **[User Guide](USER_GUIDE.md)** for a walkthrough of every screen.

## Quick start

Requirements: macOS 13 Ventura or later, and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app is not needed.

```bash
git clone https://github.com/ssridhar/storagemanager.git
cd storagemanager
./start.sh
```

`start.sh` compiles only what changed, assembles `build/Storage Manager.app` and opens it. The first build takes about 2–3 minutes; later launches are instant.

| Command | What it does |
|---|---|
| `./start.sh` | Build if needed and launch |
| `./start.sh --check` | Run the safety checks first, then launch |
| `./start.sh --install` | Also copy the app to `~/Applications` so it shows up in Spotlight and Launchpad |
| `scripts/build.sh --check` | Build and run the safety checks without launching |

The first time you scan, macOS will ask whether Storage Manager may read Desktop, Documents and Downloads. Scanning only reads file sizes. For a complete picture you can also grant **Full Disk Access** (System Settings → Privacy & Security). The app works without it and simply reports which folders it could not measure.

## Safety model

Safety is the main design constraint, and it is enforced in code rather than left to the UI:

1. **One gatekeeper.** Every removal passes through `SafetyGuard` (`Sources/StorageCore/SafetyGuard.swift`). It is an *allowlist*: only plain files in your user folder, a short list of regenerable locations in `~/Library`, and whole third-party apps can be removed. Everything else is refused, including `/System`, `/Library`, `/usr`, other users and external drives.
2. **Personal and system state is off-limits.** That covers Keychains, Mail, Messages, Safari, Calendars, accounts, iCloud Drive, Group Containers, LaunchAgents, Apple system caches, hidden settings (`.ssh`, `.zshrc`, `.config`, `.aws`…) and Git history.
3. **Bundles stay whole.** Nothing inside an `.app`, a Photos library or a Music library can be removed, and those libraries cannot be removed as a whole either.
4. **No direct deletes.** Removals are an instant rename into the Safety Vault (`~/Library/Application Support/StorageManager/Vault`), recorded in a journal and in a per-item manifest, so the journal can be rebuilt if it is lost. Permanent deletion happens only when you delete from the vault or when the retention period ends (14 days by default).
5. **Restores never overwrite.** If something new now sits at the original path, the restored item is renamed `name (restored).ext`.
6. **Guard rails in the workflows.** At least one copy of every duplicate set is always kept, files whose contents turn out to differ are deselected, apps that are running are refused, iCloud placeholders are never downloaded just to compare them, and removals from synced folders (iCloud Desktop & Documents, Dropbox, Google Drive, OneDrive) show a warning.
7. **Hard to trick.** Paths are standardized (no `..` tricks), symlinked parent folders are resolved before checking, and comparisons are case-insensitive like APFS.

The only permanent actions are **Empty Trash** and **Delete** in the vault. Both need an explicit confirmation.

`swift run SafetyChecks` (or `scripts/build.sh --check`) runs more than 70 headless checks against the guard and the vault inside a temporary folder. They never touch your real files.

## What makes it different

Existing tools (CleanMyMac, DaisyDisk, OmniDiskSweeper, GrandPerspective, AppCleaner, Gemini 2, macOS's own Storage settings) each cover part of this. These are the gaps Storage Manager targets:

| Gap in today's tools | Storage Manager |
|---|---|
| Cleaners delete or empty-Trash straight away; recovering a mistake means Time Machine, if you have it | **Safety Vault** with per-item restore to the original path, a configurable retention period and a full history log |
| "System Data" is a mystery number | Shows purgeable space, counts Time Machine local snapshots, and lists the exact folders macOS hid from the scan |
| You can't see *why* something is safe | Every suggestion explains itself and is labeled **Safe** (regenerable, pre-selected) or **Review** (your data, never pre-selected) |
| You can't see what the tool refuses to touch | Protected items show a lock with the reason, and a **Safety Rules** page lets you test any path |
| Developer bloat is ignored or deleted blindly | Xcode DerivedData and device support, simulator caches, npm/Gradle/Maven/Cargo caches and stale `node_modules`, attributed to a Developer category |
| Duplicate finders download iCloud files to hash them | Placeholders are detected and skipped; hard links are de-duplicated, so they never count as reclaimable |
| Removing a file in a synced folder silently deletes it on every device | A warning before the move |
| No sense of trend | Each scan is saved, and the overview shows per-category growth since last time |
| Subscriptions and telemetry | Free, open source, no network access, no analytics |

### Roadmap ideas

- **Growth alerts:** a menu-bar item that warns when free space drops below a threshold or a folder grows unusually fast.
- **Scheduled safe clean:** run only the *Safe* categories weekly, into the vault.
- **Time Machine snapshot thinning:** a guided `tmutil thinlocalsnapshots` with a clear explanation.
- **Similar-photo and near-duplicate detection** (perceptual hashes) as a *review-only* list.
- **External drive and NAS views** (read-only analysis).
- **Docker / VM image awareness:** explain `Docker.raw` and VM disk files and link to each tool's own prune command instead of deleting.
- **"Why is this here?"**: attribute files to the app that created them, using `kMDItemWhereFroms` and bundle IDs.
- **Ignore list:** folders you never want suggested.
- **Exportable report** (HTML/CSV) of a scan.

## Project layout

```
start.sh                     Build-if-needed and launch
scripts/build.sh             swiftc build → build/Storage Manager.app (no Xcode project needed)
scripts/make-icon.swift      Regenerates Resources/AppIcon.icns
Package.swift                SwiftPM manifest (open the folder in Xcode or VS Code)
Sources/StorageCore/         UI-free logic
  SafetyGuard.swift          The allowlist every removal must pass
  SafetyVault.swift          Move-instead-of-delete, journal, restore, purge, retention
  Scanner.swift              Parallel, read-only disk walk; large files, duplicates, node_modules
  Suggestions.swift          Clean-up categories built from a scan
  AppInventory.swift         Third-party apps, last-opened dates, leftover files
  System.swift               Disk capacity, local snapshots, Trash, content hashing, scan history
  Models.swift               Shared types
Sources/StorageManager/      SwiftUI app (Overview, Clean Up, Large Files, Duplicates, Apps, Vault, Safety Rules)
Sources/SafetyChecks/        Headless checks for the guard and the vault
```

The build scripts call `swiftc` directly because SwiftPM on some Command Line Tools installs fails with `unable to lookup item 'PlatformPath'`. If your setup has full Xcode, `swift build` and opening `Package.swift` in Xcode both work too.

## License

Not yet chosen. Add a LICENSE file before publishing.
