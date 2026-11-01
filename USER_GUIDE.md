# Storage Manager — User Guide

This guide walks through each screen and explains what is safe, what to review, and how to undo anything.

**The short version:** scanning never changes anything. When you remove something, it goes to the **Safety Vault**, not the Trash and not straight to deletion, and you can restore it with one click until the retention period ends (14 days by default).

---

## 1. Launching

From the project folder:

```bash
./start.sh
```

To launch it like any other app afterwards, install it once to `~/Applications`:

```bash
./start.sh --install
```

Then open **Storage Manager** from Spotlight (⌘Space) or Launchpad.

### Permissions you may see

| Prompt | Why | Required? |
|---|---|---|
| "Storage Manager would like to access files in your Desktop / Documents / Downloads folder" | To measure file sizes there | Recommended. Without it those folders count as "System Data" |
| Full Disk Access (System Settings → Privacy & Security) | Lets the scan measure Mail, Safari data and the Trash | Optional |
| "Storage Manager wants to control Finder" | Only when you click **Empty Trash** without Full Disk Access; Finder does the emptying | Only for that action |

Granting access lets the app *see* more. It never widens what the app may *remove*: those rules are fixed (see §8).

---

## 2. Overview

The first screen shows your startup disk.

- **The disk ring:** each colored arc is a category of storage. Hover over an arc or a row in the list to highlight it. The grey track is free space.
- **The list on the right:** the "users" of your storage, largest first. A red **+2.1 GB** or green **−800 MB** shows the change since your previous scan.
- **macOS & System Data:** everything the app doesn't measure directly: macOS itself, virtual memory, Time Machine local snapshots, other user accounts and any folders macOS didn't let the app read.
- **Purgeable:** space macOS frees by itself when it needs to, for example local snapshots and iCloud files it can download again. You don't need to do anything about it.

The cards along the bottom are shortcuts:

| Card | What it means |
|---|---|
| Safe to clean | Total of the pre-selected, regenerable items on **Clean Up** |
| Duplicates | Space you'd get back by keeping one copy of each duplicate set |
| Unused apps | Third-party apps not opened in 90 days |
| Trash | What's in the Trash now. **Empty…** is permanent |
| Safety Vault | What you've removed with this app that can still be restored |
| Purgeable | See above |

If an orange note says some folders could not be measured, click **Open Full Disk Access Settings** to grant access. This is optional.

Press **⌘R** or click the ↻ toolbar button to rescan at any time.

---

## 3. Clean Up

Suggestions are grouped into cards. Each card says what the items are and why they're safe, and carries a label:

- **Safe** (green): data that apps or tools recreate automatically. Pre-selected.
- **Review** (orange): your own files, or things that take effort to get back. **Nothing is pre-selected.** Tick only what you recognize.

| Card | Label | Notes |
|---|---|---|
| App caches | Safe | `~/Library/Caches`. Apple system caches are never included. Quit the apps first for the best result |
| Old log files | Safe | `~/Library/Logs` |
| Xcode build data | Safe | DerivedData, device support and simulator caches. Rebuilt on the next build or device connection |
| Package manager caches | Safe | npm, Gradle, Maven and Cargo download caches |
| Installer files | Review | `.dmg`, `.pkg`, `.iso`, `.xip` files |
| Old downloads | Review | Items in Downloads untouched for 90+ days |
| Unused node_modules | Review | JavaScript dependency folders untouched for 30+ days. `npm install` restores them |
| iPhone & iPad backups | Review | Remove only backups you have a newer copy of |

**How to clean:**
1. Expand a card ("N of M selected") to see the items, use the checkboxes, and click 🔍 to view an item in Finder.
2. Click **Clean Selected** at the top.
3. Review the confirmation sheet: it lists what will move and anything protected that will be skipped.
4. Click **Move to Safety Vault**.

> **Freeing the space:** items in the vault still take up space until they are deleted. To get the space back immediately, open **Safety Vault** and use **Delete…** or **Delete All Now…**. Otherwise they are deleted automatically after the retention period.

---

## 4. Large Files

All files over 100 MB in your user folder, largest first.

- Type in the search field to filter by name or folder.
- Switch the toolbar control to **Oldest first** to find big files you haven't touched in years.
- Double-click a row, or right-click → **Show in Finder**, to see the file.
- A 🔒 means the file is protected (hover for the reason). For example, a large virtual machine image inside an app's container is shown so you know it's there, but it can't be removed from here. Use that app's own tools.
- Select rows (⌘-click or ⇧-click) and click **Move to Safety Vault…**.

---

## 5. Duplicates

Files with the **same name and the same size** in **different folders**.

- Each set shows how many copies exist and how much you'd reclaim.
- The **oldest copy is kept** by default and the others are marked **Remove**. Change this with the checkboxes. The app won't let you mark every copy: the last kept checkbox is locked.
- **Verify** compares the copies byte for byte:
  - ✅ **Identical**: safe to remove the extras.
  - ⚠️ **Contents differ**: they only share a name and size. All are deselected automatically.
  - ☁️ **In iCloud only**: not downloaded to your Mac, so not compared (comparing would download them).
- **Verify All** checks the first 200 sets in the background.
- Click **Move Selected Copies to Safety Vault…** when you're done.

Hard links (two names for the same data) are recognized and never shown, because removing one frees nothing.

---

## 6. Apps

Third-party apps in `/Applications` and `~/Applications`. Apple's own apps are part of macOS and are never listed.

- **Unused 90+ days** (toolbar switch) narrows the list to apps you haven't opened recently, based on Spotlight's "last opened" date. "Never / unknown" means it was never opened or Spotlight indexing is off.
- **Source** shows whether the app came from the App Store, in which case you can re-download it for free from your purchase history.
- **Also remove the app's support files and settings** includes leftovers in `~/Library` that match the app's exact bundle ID or name: Application Support, Caches, Preferences, Containers, saved state, web data and logs. You see every one in the confirmation sheet before anything moves.
- Running apps are refused. Quit the app first.

> Apps installed by an installer package (owned by the system) may fail to move with a permissions error. Drag those to the Trash in Finder, or use the vendor's uninstaller.

---

## 7. Safety Vault — undoing a removal

Everything you remove with Storage Manager is listed here.

- **Restore** puts the item back at its exact original location and recreates missing folders. If a different file now uses that name, the restored one is saved as `name (restored).ext`, so nothing is overwritten.
- **Delete…** permanently deletes one item and frees its space. This can't be undone.
- **Delete All Now…** does the same for everything in the vault.
- **Keep items for** sets the retention period (3–60 days). Items older than that are deleted automatically the next time the app starts.
- **History** records every restore and deletion.
- Use the search field to find an item by name or original folder.

**If something went missing**, look here first and search for its name. The vault lives at `~/Library/Application Support/StorageManager/Vault`. Each item sits in its own folder with a `.manifest.json` describing where it came from, so even without the app you can move a file back by hand.

> **Empty Trash is different:** it permanently deletes what's in the macOS Trash (things *you* put there in Finder). It doesn't affect the Safety Vault.

---

## 8. Safety Rules

This page lists, in plain language, what the app will never touch. It also has a **Check a path** box: paste any path (for example `~/Library/Keychains`) to see whether the app would allow removing it and why.

In summary:

- Only your user folder and whole third-party apps are ever eligible.
- macOS system folders, other users, external drives, keychains, mail, messages, iCloud Drive, browser data, hidden settings and Git history are always refused.
- Nothing inside apps or Photos/Music libraries is touched.
- Nothing is deleted without going through the vault, except **Empty Trash** and **Delete** in the vault, which always ask first.

---

## 9. FAQ

**I cleaned 10 GB but free space didn't change.**
The items are in the Safety Vault. Delete them there to free the space now, or wait for the retention period.

**Why is "macOS & System Data" so big?**
It includes macOS, swap, Time Machine local snapshots (see the Purgeable card) and folders the app couldn't read. Granting Full Disk Access moves more of it into named categories.

**Will cleaning caches break my apps?**
No. Apps recreate caches as needed, though they may be a little slower the first time. Apple system caches are never included.

**Does the app send any data anywhere?**
No. It makes no network connections.

**Where are the app's own files?**
`~/Library/Application Support/StorageManager`: the vault, its journal (`vault-journal.json`) and scan history (`scan-history.json`).

**How do I uninstall Storage Manager?**
Delete or restore anything left in the vault first. Then remove the app and the `~/Library/Application Support/StorageManager` folder.
