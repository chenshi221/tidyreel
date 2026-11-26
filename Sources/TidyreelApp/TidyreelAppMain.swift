import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelHealthUI
import TidyreelModels
import TidyreelReviewUI
import TidyreelServices
import TidyreelSettingsUI
import TidyreelSourcesUI
import TidyreelTasksUI

@main
struct TidyreelNativeApp: App {
    @NSApplicationDelegateAdaptor(TidyreelAppDelegate.self) private var appDelegate
    @State private var store: AppStore = {
        let token = BuiltInSecrets.tmdbToken
        if let live = try? AppStore.openLive(
            builtInTmdbToken: token,
            fetchArtworkBytes: { await ArtworkCache.shared.fetchRawBytes(url: $0) },
            clearArtworkCache: { await ArtworkCache.shared.clearAll() }
        ) {
            return live
        }
        return try! AppStore.makeDemo()
    }()

    var body: some Scene {
        WindowGroup(store.l10n.appTitle) {
            AppShellView(store: store)
                .frame(minWidth: 1080, minHeight: 680)
                .background(MainWindowConfigurator(title: store.l10n.appTitle))
                .onAppear {
                    appDelegate.store = store
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button(store.l10n.tr("隐藏窗口", "Close Window")) {
                    NSApp.keyWindow?.orderOut(nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
            CommandGroup(after: .textEditing) {
                Button(store.l10n.tr("命令面板…", "Command Palette…")) {
                    store.isCommandPalettePresented = true
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
            CommandMenu(store.l10n.tr("导航", "Navigate")) {
                Button(store.l10n.tr("来源", "Sources")) { store.navigateToTab(.sources) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button(store.l10n.tr("任务", "Tasks")) { store.navigateToTab(.tasks) }
                    .keyboardShortcut("2", modifiers: [.command])
                Button(store.l10n.tr("体检", "Health")) { store.navigateToTab(.health) }
                    .keyboardShortcut("3", modifiers: [.command])
                Button(store.l10n.tr("命名规则", "Naming")) { store.navigateToTab(.naming) }
                    .keyboardShortcut("4", modifiers: [.command])
                Button(store.l10n.tr("设置", "Settings")) { store.navigateToTab(.settings) }
                    .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

/// Configures the primary macOS window so clicking the red close button (`×`) or pressing `⌘W`
/// hides the window (`orderOut`) instead of terminating background tasks; Dock click brings it back (`⌘Q` quits).
private struct MainWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window, title: title)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.attach(to: window, title: title)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var attachedWindow: NSWindow?

        func attach(to window: NSWindow, title: String) {
            if window.title != title {
                window.title = title
            }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            guard attachedWindow !== window else { return }
            attachedWindow = window
            window.delegate = self
            window.isReleasedWhenClosed = false
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }
    }
}

final class TidyreelAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        store?.shutdownSync()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.shutdownSync()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
            if sender.windows.allSatisfy({ !$0.isVisible }), let first = sender.windows.first {
                first.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

enum BuiltInSecrets {
    static var tmdbToken: String {
        if let env = ProcessInfo.processInfo.environment["TMDB_TOKEN"], !env.isEmpty {
            return env
        }
        if let infoVal = Bundle.main.object(forInfoDictionaryKey: "TIDYREEL_DEFAULT_TMDB_TOKEN") as? String,
           !infoVal.isEmpty {
            return infoVal
        }
        return ""
    }
}
