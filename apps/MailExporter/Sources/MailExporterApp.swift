import AppKit
import SwiftUI

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
        }
        .defaultSize(width: 960, height: 640)
        // Claim file-open events so a Dock/Finder drop orders this window front.
        // (matching: [] left the window behind on cold-start drops.)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {}
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
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    Task {
                        await AppUpdater.shared.checkForUpdates(silent: false)
                    }
                }
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(prefs)
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--bench") {
            runBenchAndExit()
            return
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
        ComposeInbox.shared.enqueue(urls)
        Self.bringToForegroundRepeatedly()
        DispatchQueue.main.async {
            Self.closeSurplusWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Self.closeSurplusWindows()
            Self.focusMainWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.focusMainWindow()
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

    static func focusMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        _ = TransformProcessType(&psn, ProcessApplicationTransformState(kProcessTransformToForegroundApplication))
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        guard let win = mainWindows().first ?? NSApp.windows.first else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }
        win.collectionBehavior.insert(.moveToActiveSpace)
        win.orderFrontRegardless()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func runBenchAndExit() {
        NSApp.setActivationPolicy(.accessory)
        let store = JobsStore()
        let config = JobsStore.defaultConfigURL()
        let root = store.projectRoot
        var args = ["export", "--dry-run", "--bench"]
        if let idx = CommandLine.arguments.firstIndex(of: "--job-name"),
           idx + 1 < CommandLine.arguments.count
        {
            args += ["--job-name", CommandLine.arguments[idx + 1]]
        } else if let firstJob = store.jobs.first {
            args += ["--job-name", firstJob.name]
        } else {
            args += ["--job-name", "Receipts"]
        }
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let first = try EngineBridge.run(
                projectRoot: root, arguments: args, configPath: config
            )
            let t1 = CFAbsoluteTimeGetCurrent()
            let second = try EngineBridge.run(
                projectRoot: root, arguments: args, configPath: config
            )
            let t2 = CFAbsoluteTimeGetCurrent()
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MailExporter")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let text = """
            {"first_wall_s":\(t1 - t0),"second_wall_s":\(t2 - t1),"first":\(first.rawJSON),"second":\(second.rawJSON)}
            """
            try text.write(
                to: support.appendingPathComponent("bench.json"),
                atomically: true,
                encoding: String.Encoding.utf8
            )
            fputs(
                "first=\(String(format: "%.3f", t1 - t0))s second=\(String(format: "%.3f", t2 - t1))s\n",
                stdout
            )
            exit(first.ok && second.ok ? 0 : 2)
        } catch {
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MailExporter")
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let msg = error.localizedDescription
            let escaped = msg.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            try? "{\"ok\":false,\"error\":\"\(escaped)\"}\n".write(
                to: support.appendingPathComponent("bench.json"),
                atomically: true,
                encoding: .utf8
            )
            fputs("bench failed: \(msg)\n", stderr)
            exit(1)
        }
    }
}
