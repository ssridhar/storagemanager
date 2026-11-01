import AppKit
import StorageCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (e.g. `swift run`) so the window comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct StorageManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Storage Manager", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan") { state.scan() }
                    .keyboardShortcut("r")
                    .disabled(state.isScanning)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $state.section) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { scanStatus.padding(12) }
        } detail: {
            detail
                .toolbar {
                    ToolbarItem {
                        Button { state.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                            .disabled(state.isScanning)
                            .help("Scan again (⌘R)")
                    }
                }
        }
        .sheet(item: $state.pending) { action in
            ConfirmSheet(action: action).environmentObject(state)
        }
        .alert(state.report?.title ?? "", isPresented: Binding(
            get: { state.report != nil }, set: { if !$0 { state.report = nil } })) {
            Button("OK") { state.report = nil }
        } message: {
            Text(state.report?.message ?? "")
        }
        .onAppear { if state.result == nil { state.scan() } }
    }

    @ViewBuilder private var detail: some View {
        switch state.section ?? .overview {
        case .overview: OverviewView()
        case .cleanup: CleanupView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .apps: AppsView()
        case .vault: VaultView()
        case .safety: SafetyRulesView()
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .vault: return state.vaultEntries.filter { $0.state == .held }.count
        case .duplicates: return state.result?.duplicateGroups.count ?? 0
        default: return 0
        }
    }

    @ViewBuilder private var scanStatus: some View {
        if state.isScanning {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: state.scanFraction)
                Text("Scanning… \(state.scanFiles.formatted()) files")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let result = state.result {
            Text("Scanned \(result.filesScanned.formatted()) files \(result.date.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
