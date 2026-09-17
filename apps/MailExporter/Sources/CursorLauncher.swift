import AppKit
import Foundation

enum CursorLauncher {
    static func openFolder(_ rawPath: String) {
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let candidates = [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            NSHomeDirectory() + "/.local/bin/cursor",
        ]
        if let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = [path]
            try? proc.run()
            return
        }
        let app = URL(fileURLWithPath: "/Applications/Cursor.app")
        if FileManager.default.fileExists(atPath: app.path) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: app,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
