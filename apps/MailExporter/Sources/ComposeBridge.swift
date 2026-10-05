import AppKit
import Foundation

struct ComposeResult: Equatable {
    var ok: Bool
    var summary: String
    var detail: String
}

enum AttachCountCheck {
    /// ``attached N of M`` from Make Mail Draft. Nil when the script did not report.
    static func parse(_ text: String) -> (attached: Int, requested: Int)? {
        let pattern = #"attached\s+(\d+)\s+of\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges == 3,
              let attachedRange = Range(match.range(at: 1), in: text),
              let requestedRange = Range(match.range(at: 2), in: text),
              let attached = Int(text[attachedRange]),
              let requested = Int(text[requestedRange])
        else {
            return nil
        }
        return (attached, requested)
    }

    static func mismatch(in text: String, requestedHint: Int = 0) -> Bool {
        if let parsed = parse(text) {
            return parsed.attached != parsed.requested
        }
        if requestedHint > 0 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "OK"
        }
        return false
    }
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
                detail: "Drop .md files (with email front matter) onto the Export drop zone."
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

        let blob = [outText, errText].filter { !$0.isEmpty }.joined(separator: "\n")
        if process.terminationStatus != 0 || AttachCountCheck.mismatch(in: blob) {
            let msg = blob.isEmpty
                ? "osascript exited \(process.terminationStatus)"
                : blob
            let parsed = AttachCountCheck.parse(blob)
            let summary: String
            if let parsed, parsed.attached != parsed.requested {
                summary = "Attachments missing (\(parsed.attached) of \(parsed.requested))"
            } else if process.terminationStatus != 0 {
                summary = "Compose failed"
            } else {
                summary = "Attachments missing"
            }
            return ComposeResult(ok: false, summary: summary, detail: msg)
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
