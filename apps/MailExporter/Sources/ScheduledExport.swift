import Foundation

/// Removes the old hourly Export All timer. The app does not install a new one.
enum ScheduledExport {
    static let label = "com.dwkns.MailExporter.hourly"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func remove() {
        let uid = getuid()
        _ = run(["/bin/launchctl", "bootout", "gui/\(uid)/\(label)"])
        _ = run(["/bin/launchctl", "unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        UserDefaults.standard.set(false, forKey: "scheduledExportEnabled")
    }

    private static func run(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return 1
        }
        return proc.terminationStatus
    }
}
