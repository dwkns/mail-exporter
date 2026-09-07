import AppKit
import Foundation

struct ComposeResult: Equatable {
    var ok: Bool
    var summary: String
    var detail: String
}

enum ComposeBridge {
    /// Bundled Make Mail Draft AppleScript (reply + GUI Attach Files path).
    static func scriptURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/MakeMailDraft.applescript")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        var candidates = [
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/MakeMailDraft.applescript"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("apps/MailExporter/Resources/MakeMailDraft.applescript"),
        ]
        if let env = ProcessInfo.processInfo.environment["MAILEXPORTER_ROOT"] {
            candidates.append(URL(fileURLWithPath: env).appendingPathComponent("apps/MailExporter/Resources/MakeMailDraft.applescript"))
        }
        candidates.append(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(
                    "Developer/mail-exporter/apps/MailExporter/Resources/MakeMailDraft.applescript"
                )
        )
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Open drafts via AppleScript (Make Mail Draft).
    static func compose(markdownFiles: [URL]) throws -> ComposeResult {
        let mdFiles = markdownFiles.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "md" || ext == "markdown" || ext == "txt"
        }
        guard !mdFiles.isEmpty else {
            return ComposeResult(
                ok: false,
                summary: "No markdown files",
                detail: "Drop .md files (with email front matter) onto Send Messages."
            )
        }
        return try composeViaAppleScript(mdFiles: mdFiles)
    }

    private static func composeViaAppleScript(mdFiles: [URL]) throws -> ComposeResult {
        guard let script = scriptURL() else {
            throw NSError(
                domain: "MailExporter",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "MakeMailDraft.applescript is missing from the app bundle.",
                ]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [script.path] + mdFiles.map(\.path)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()

        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let msg = errText.isEmpty ? outText : errText
            return ComposeResult(
                ok: false,
                summary: "Compose failed",
                detail: msg.isEmpty
                    ? "osascript exited \(process.terminationStatus)"
                    : msg
            )
        }

        let detail = outText.isEmpty || outText == "OK"
            ? "Opened \(mdFiles.count) draft(s) in Mail."
            : outText
        let summary = mdFiles.count == 1
            ? "Draft opened in Mail"
            : "\(mdFiles.count) drafts opened in Mail"
        return ComposeResult(ok: true, summary: summary, detail: detail)
    }
}
