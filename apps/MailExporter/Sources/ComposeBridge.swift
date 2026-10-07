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
