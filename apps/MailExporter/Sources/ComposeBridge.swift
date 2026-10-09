import AppKit
import Foundation
import UserNotifications

struct ComposeResult: Equatable {
    var ok: Bool
    var summary: String
    var detail: String
}

enum AttachCountCheck {
    /// ``attached N of M`` from a draft result. Nil when the result did not report.
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

/// Plain words for a failed draft. One failure sentence and one recovery sentence.
enum ComposeFailureCopy {
    static func banner(summary: String, detail: String) -> String {
        let raw = summary + "\n" + detail
        let blob = raw.lowercased()
        if isMissingQuote(blob) {
            return join(countNote(raw), missingQuoteFailure, missingQuoteRecovery)
        }
        if blob.contains("attachment not found") {
            return join(countNote(raw), "An attachment file is missing.", "Put the file inside the project folder, fix the Attach line, and drop the Markdown again.")
        }
        if blob.contains("must stay inside the project") {
            return join(countNote(raw), "An attachment is outside the project folder.", "Move the file into the project, update the Attach line, and drop the Markdown again.")
        }
        if blob.contains("file not found") || blob.contains("no markdown files") {
            return join(nil, "The Markdown file is missing.", "Choose the file again from its folder.")
        }
        if let counts = mismatchedCounts(raw) {
            return "Mail attached \(counts.attached) of \(counts.requested) files. Check that every path on the Attach line is a file inside the project, then drop the Markdown again."
        }
        if MailAccessProbe.looksLikeAutomationDenial(raw) {
            return join(countNote(raw), "Mail did not allow this app to control it.", "Turn on Automation for MailExporter under Privacy & Security, then drop the file again.")
        }
        if isMailSilent(blob) {
            return join(countNote(raw), "Mail did not answer.", "Open Mail and leave it running, then drop the file again.")
        }
        if blob.contains("security add-generic-password") || blob.contains("mailexporter icloud imap") {
            return join(countNote(raw), "No password is stored for this iCloud account.", "Add a keychain item named MailExporter iCloud IMAP for the From address, then drop the file again.")
        }
        if isImportOrServer(blob) {
            return join(countNote(raw), "Mail could not import the draft.", "Leave Mail open and drop the file again.")
        }
        return join(countNote(raw), "The draft was not created.", "Check the Markdown file, then drop it again.")
    }

    private static let missingQuoteFailure = "This reply has no original message to quote."
    private static let missingQuoteRecovery = "Add an In-Reply-To line whose value is the Message-ID of an exported .eml in the project Email folder, or set Reply: new if it is not a reply."

    private static func isMissingQuote(_ blob: String) -> Bool {
        blob.contains("in-reply-to")
            || blob.contains("no exported .eml")
            || blob.contains("invent a quote")
            || blob.contains("quote missing")
    }

    private static func isMailSilent(_ blob: String) -> Bool {
        blob.contains("mail did not show the draft")
            || blob.contains("mail came to the front")
            || blob.contains("mail window appeared")
            || blob.contains("could not compile")
            || blob.contains("no account")
    }

    private static func isImportOrServer(_ blob: String) -> Bool {
        blob.contains("import")
            || blob.contains("imap")
            || blob.contains("append")
            || blob.contains("not reachable")
            || blob.contains("no continuation")
            || blob.contains("login failed")
    }

    /// Present only when the attachment count itself is wrong.
    private static func countNote(_ raw: String) -> String? {
        guard let counts = mismatchedCounts(raw) else { return nil }
        return "Mail attached \(counts.attached) of \(counts.requested) files."
    }

    private static func mismatchedCounts(_ raw: String) -> (attached: Int, requested: Int)? {
        guard let counts = AttachCountCheck.parse(raw), counts.requested > 0, counts.attached != counts.requested else {
            return nil
        }
        return counts
    }

    private static func join(_ count: String?, _ failure: String, _ recovery: String) -> String {
        [count, failure, recovery].compactMap { $0 }.joined(separator: " ")
    }
}

enum ComposeBridge {
    /// Open drafts in the background. Upload when iCloud IMAP is ready. Import otherwise.
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
        var lines: [String] = []
        var ok = true
        for file in mdFiles {
            let payload = HiddenDraft.run(path: file.path, subjectOverride: "", method: "auto")
            let text = (payload["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let err = (payload["error"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = [text, err].filter { !$0.isEmpty }.joined(separator: " ")
            if !line.isEmpty { lines.append(line) }
            if (payload["ok"] as? Bool) != true { ok = false }
        }
        let detail = lines.joined(separator: "\n")
        if !ok {
            let parsed = AttachCountCheck.parse(detail)
            let summary: String
            if let parsed, parsed.attached != parsed.requested {
                summary = "Attachment count is wrong (\(parsed.attached) of \(parsed.requested))"
            } else {
                summary = "Compose failed"
            }
            return ComposeResult(ok: false, summary: summary, detail: detail)
        }
        let summary = mdFiles.count == 1
            ? "Draft opened in Mail"
            : "\(mdFiles.count) drafts opened in Mail"
        let shown = detail.isEmpty ? "Opened \(mdFiles.count) draft(s) in Mail." : detail
        return ComposeResult(ok: true, summary: summary, detail: shown)
    }
}

enum DraftNotifier {
    /// Tell the user the draft work has finished, including file attachment.
    static func announce(_ result: ComposeResult, draftCount: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "MailExporter"
            content.body = message(for: result, draftCount: draftCount)
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    static func message(for result: ComposeResult, draftCount: Int) -> String {
        let count = max(draftCount, 1)
        let draftWord = count == 1 ? "Draft ready." : "\(count) drafts ready."
        if let counts = AttachCountCheck.parse(result.detail), counts.requested > 0 {
            let files = "\(counts.attached) of \(counts.requested) files attached."
            if result.ok {
                return "\(draftWord) \(files)"
            }
            return "Draft not ready. \(files)"
        }
        if result.ok {
            return draftWord
        }
        return result.summary
    }
}
