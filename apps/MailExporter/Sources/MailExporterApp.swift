import AppKit
import SwiftUI

extension Notification.Name {
    static let mailExporterNewExport = Notification.Name("mailExporterNewExport")
    static let mailExporterExportAll = Notification.Name("mailExporterExportAll")
    static let mailExporterExportJob = Notification.Name("mailExporterExportJob")
    static let mailExporterShowFolder = Notification.Name("mailExporterShowFolder")
    static let mailExporterPermissionsChanged = Notification.Name("mailExporterPermissionsChanged")
}

enum MailExporterURL {
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "mailexporter" else { return }
        let host = (url.host ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        switch host {
        case "export-all", "export":
            NotificationCenter.default.post(name: .mailExporterExportAll, object: nil)
        case "export-job":
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "name" })?
                .value
            if let name, !name.isEmpty {
                NotificationCenter.default.post(
                    name: .mailExporterExportJob,
                    object: nil,
                    userInfo: ["name": name]
                )
            }
        case "new":
            NotificationCenter.default.post(name: .mailExporterNewExport, object: nil)
        default:
            break
        }
    }
}

@main
struct MailExporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = JobsStore()
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some Scene {
        // Single main window — file opens must not spawn extras (handled in AppDelegate).
        Window("MailExporter", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(prefs)
                .frame(minWidth: 900, minHeight: 580)
                .background(HiddenWindowTitle())
        }
        .defaultSize(width: 960, height: 640)
        // Claim file-open events so a Dock/Finder drop orders this window front.
        // (matching: [] left the window behind on cold-start drops.)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    NotificationCenter.default.post(name: .mailExporterNewExport, object: nil)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Export All") {
                    NotificationCenter.default.post(name: .mailExporterExportAll, object: nil)
                }
                .keyboardShortcut("e")
                .disabled(store.jobs.isEmpty)
            }
            CommandGroup(replacing: .importExport) {
                Button("Import Settings…") {
                    store.promptImportSettings()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Export Settings…") {
                    store.promptExportSettings()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    AppUpdater.shared.showUpdateWindow()
                }
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(prefs)
                .environmentObject(store)
                .background(HiddenWindowTitle())
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--bench") {
            FileHandle.standardError.write(
                Data("MailExporter no longer accepts --bench; use the engine CLI.\n".utf8)
            )
            exit(2)
        }
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        EngineBridge.prewarm()
        // Finder sometimes passes paths as argv when launching by drop.
        let argvFiles = CommandLine.arguments.dropFirst().compactMap { arg -> URL? in
            if arg.hasPrefix("-") { return nil }
            let url = URL(fileURLWithPath: arg)
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" || ext == "txt" else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        if !argvFiles.isEmpty {
            ComposeInbox.shared.enqueue(Array(argvFiles))
        }
        Self.bringToForegroundRepeatedly()
    }

    /// Dock / Finder drop onto the app icon (and `open -a MailExporter file.md`).
    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if url.scheme?.lowercased() == "mailexporter" {
                MailExporterURL.handle(url)
                continue
            }
            files.append(url)
        }
        if !files.isEmpty {
            ComposeInbox.shared.enqueue(files)
        }
        DispatchQueue.main.async {
            Self.closeSurplusWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Self.closeSurplusWindows()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Space swipes fire this. Do not order-front or move the window onto
        // the active space — that hides MailExporter when leaving Cursor.
        Self.keepWindowOnAssignedSpace()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Self.focusMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Bring MailExporter in front of Finder/Mail on cold start. The SwiftUI
    /// window often does not exist yet in applicationDidFinishLaunching.
    static func bringToForegroundRepeatedly() {
        focusMainWindow()
        for delay in [0.05, 0.15, 0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                focusMainWindow()
            }
        }
    }

    /// Prefer the SwiftUI main window; ignore Settings / panels.
    static func mainWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            if window.frameAutosaveName.lowercased().contains("preferences") { return false }
            if window.frameAutosaveName.lowercased().contains("settings") { return false }
            return window.contentView != nil
        }
        .sorted { a, b in
            (a.frame.width * a.frame.height) > (b.frame.width * b.frame.height)
        }
    }

    /// Launch / Dock reopen only. Never call from compose or `didBecomeActive`
    /// (Mission Control space swipes). Does not steal the window onto another Space.
    static func focusMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        guard let win = mainWindows().first ?? NSApp.windows.first else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }
        Self.keepWindowOnAssignedSpace(win)
        win.makeKeyAndOrderFront(nil)
    }

    /// Stay on the Space the user placed the window. `.moveToActiveSpace` made
    /// MailExporter vanish when swiping Cursor → Desktop with Mail also open.
    static func keepWindowOnAssignedSpace(_ window: NSWindow? = nil) {
        let targets = window.map { [$0] } ?? mainWindows()
        for win in targets {
            win.collectionBehavior.remove(.moveToActiveSpace)
            win.collectionBehavior.remove(.canJoinAllSpaces)
        }
    }

    static func closeSurplusWindows() {
        let mains = mainWindows()
        guard mains.count > 1, let keep = mains.first else { return }
        for window in mains.dropFirst() {
            // Don't close the Settings scene if somehow included
            if window === keep { continue }
            if window.frame.width >= 800 && window.frame.height >= 500 {
                window.close()
            }
        }
    }

}
