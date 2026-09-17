import Foundation

enum ScheduledExport {
    static let label = "com.dwkns.MailExporter.hourly"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func setEnabled(_ enabled: Bool) -> String {
        enabled ? install() : uninstall()
    }

    private static func install() -> String {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>mailexporter://export-all</string>
          </array>
          <key>StartInterval</key>
          <integer>3600</integer>
          <key>RunAtLoad</key>
          <false/>
        </dict>
        </plist>
        """
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
            let uid = getuid()
            _ = run(["/bin/launchctl", "bootout", "gui/\(uid)/\(label)"])
            let boot = run(["/bin/launchctl", "bootstrap", "gui/\(uid)", plistURL.path])
            if boot.status != 0 && !(boot.out + boot.err).contains("already") {
                _ = run(["/bin/launchctl", "load", "-w", plistURL.path])
            }
            return "Hourly Export All is on. MailExporter will open and export once an hour."
        } catch {
            return "Couldn’t install schedule: \(error.localizedDescription)"
        }
    }

    private static func uninstall() -> String {
        let uid = getuid()
        _ = run(["/bin/launchctl", "bootout", "gui/\(uid)/\(label)"])
        _ = run(["/bin/launchctl", "unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        return "Hourly Export All is off."
    }

    private static func run(_ args: [String]) -> (status: Int32, out: String, err: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, out, err)
    }
}
