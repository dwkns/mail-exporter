import AppKit
import Foundation
import Network

/// Hidden Mail drafts. Ports lab/hidden-draft-f51a (draftmime.py, imap_draft.py,
/// hidden_draft.py with IMPORT_FORMAT=emlx). Never sends. Never opens SMTP.
enum HiddenDraft {
    static let service = "MailExporter iCloud IMAP"
    static let host = "imap.mail.me.com"
    static let port: UInt16 = 993

    struct Spec {
        var to: [String] = []
        var cc: [String] = []
        var from = ""
        var subject = ""
        var inReplyTo = ""
        var replyMode = "auto"
        var format = "markdown"
        var attach: [String] = []
        var body = ""
    }

    struct Built {
        var mime: Data
        var requested: Int
        var messageID: String
        var inReplyTo: String
        var replyMode: String
        var subject: String
        var plainBody: String
        var bodyNeedle: String
        var quoteNeedle: String
        var wantsBold: Bool
        var wantsList: Bool
        var fromAddress: String
    }

    /// Socket and drop-zone entry. `method` is upload, import, or auto.
    static func run(path: String, subjectOverride: String, method: String) -> [String: Any] {
        let started = Date()
        let frontBefore = frontmost()
        let windowsBefore = mailWindowCount()
        var payload: [String: Any] = [
            "ok": false,
            "result": "",
            "method": method,
            "attached": -1,
            "requested": 0,
            "names": [String](),
            "to": "",
            "cc": "",
            "subject": subjectOverride,
            "inReplyToPresent": false,
            "quote": false,
            "formatting": false,
            "draftRowID": "",
            "serverUID": NSNull(),
            "seconds": [String: Double](),
            "leftoverMailbox": "",
            "error": "",
            "warnings": [String](),
            "passwordItem": false,
            "frontBefore": frontBefore,
            "frontAfter": frontBefore,
            "mailWindowsBefore": windowsBefore,
            "mailWindowsAfter": windowsBefore,
        ]
        func finish(_ extra: [String: Any]) -> [String: Any] {
            var out = payload
            for (k, v) in extra { out[k] = v }
            out["frontAfter"] = frontmost()
            out["mailWindowsAfter"] = mailWindowCount()
            let became = (out["frontBefore"] as? String) != "com.apple.mail"
                && (out["frontAfter"] as? String) == "com.apple.mail"
            let rose = (out["mailWindowsAfter"] as? Int ?? 0) > (out["mailWindowsBefore"] as? Int ?? 0)
            var warnings = out["warnings"] as? [String] ?? []
            if became || rose {
                warnings.append(became ? "Mail came to the front" : "A Mail window appeared")
            }
            out["warnings"] = warnings
            let total = Date().timeIntervalSince(started)
            var seconds = out["seconds"] as? [String: Double] ?? [:]
            seconds["total"] = (total * 100).rounded() / 100
            out["seconds"] = seconds
            return out
        }

        let chosen = method.isEmpty ? "auto" : method
        guard chosen == "auto" || chosen == "upload" || chosen == "import" else {
            return finish(["error": "method must be upload, import, or auto", "result": "attached 0 of 0"])
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return finish(["error": "file not found: \(url.path)", "result": "attached 0 of 0"])
        }
        let tBuild = Date()
        let built: Built
        do {
            var spec = try parse(try String(contentsOf: url, encoding: .utf8))
            if !subjectOverride.isEmpty { spec.subject = subjectOverride }
            built = try build(spec: spec, md: url)
        } catch {
            return finish([
                "error": error.localizedDescription,
                "result": "attached 0 of 0",
                "seconds": ["build": elapsed(tBuild)],
            ])
        }
        payload["requested"] = built.requested
        payload["subject"] = built.subject
        var seconds: [String: Double] = ["build": elapsed(tBuild)]

        var setupLine = ""
        if chosen != "import" {
            let password = keychainPassword(account: built.fromAddress)
            payload["passwordItem"] = password != nil
            if let password {
                let tConnect = Date()
                switch upload(mime: built.mime, user: built.fromAddress, password: password) {
                case .uploaded(let uid, let connect, let append, let raw):
                    seconds["connect"] = connect
                    seconds["upload"] = append
                    payload["serverUID"] = uid
                    payload["method"] = "upload"
                    payload["seconds"] = seconds
                    var fields = fieldsFromUpload(built: built, raw: raw)
                    fields["seconds"] = seconds
                    return finish(fields)
                case .offline:
                    seconds["connect"] = elapsed(tConnect)
                    if chosen == "upload" {
                        payload["method"] = "upload"
                        payload["seconds"] = seconds
                        payload["error"] = "Mail server was not reachable within 3 seconds."
                        payload["result"] = "attached 0 of \(built.requested)"
                        return finish([:])
                    }
                    setupLine = "Mail server was not reachable within 3 seconds."
                case .failed(let message):
                    if chosen == "upload" {
                        payload["method"] = "upload"
                        payload["seconds"] = seconds
                        payload["error"] = message
                        payload["result"] = "attached 0 of \(built.requested)"
                        return finish([:])
                    }
                    setupLine = message
                }
            } else if chosen == "upload" {
                payload["method"] = "upload"
                payload["seconds"] = seconds
                payload["error"] = "security add-generic-password -a \(built.fromAddress) -s \"\(service)\" -w"
                payload["result"] = "attached 0 of \(built.requested)"
                return finish([:])
            } else {
                setupLine = "security add-generic-password -a \(built.fromAddress) -s \"\(service)\" -w"
            }
        } else {
            payload["passwordItem"] = keychainPassword(account: built.fromAddress) != nil
        }

        ensureMail()

        payload["method"] = "import"
        let tImport = Date()
        let imported = importDraft(built)
        seconds["import"] = imported.importSeconds
        seconds["move"] = imported.moveSeconds
        payload["seconds"] = seconds
        payload["leftoverMailbox"] = imported.leftover
        if let err = imported.error {
            let line = [setupLine, err].filter { !$0.isEmpty }.joined(separator: " ")
            return finish([
                "ok": false,
                "error": line,
                "result": "attached 0 of \(built.requested)",
                "seconds": seconds,
            ])
        }
        let waited = verify(built, seconds: &seconds)
        seconds["wait"] = waited.wait
        var fields = verifyFields(waited, built: built, leftover: imported.leftover)
        fields["seconds"] = seconds
        if !setupLine.isEmpty {
            let err = fields["error"] as? String ?? ""
            fields["error"] = err.isEmpty ? setupLine : setupLine + " " + err
        }
        _ = tImport
        return finish(fields)
    }

    // MARK: - Markdown and MIME (draftmime.py)

    static func parse(_ raw: String) throws -> Spec {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var header = ""
        var body = text
        let trimmed = text.lstripNewlines()
        if trimmed.hasPrefix("---") {
            let lines = trimmed.components(separatedBy: "\n")
            if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
               let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                header = lines[1..<end].joined(separator: "\n")
                body = lines[(end + 1)...].joined(separator: "\n")
                if body.hasPrefix("\n") { body.removeFirst() }
            }
        }
        var spec = Spec()
        var headers: [String: String] = [:]
        var current = ""
        for line in header.components(separatedBy: "\n") {
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = key
                if key == "attach" || key == "attachment" || key == "attachments" {
                    let prev = headers["attach"] ?? ""
                    headers["attach"] = prev.isEmpty ? value : prev + ", " + value
                    current = "attach"
                } else {
                    headers[key] = value
                }
            } else if current == "attach" {
                let extra = line.trimmingCharacters(in: .whitespaces)
                if !extra.isEmpty {
                    let prev = headers["attach"] ?? ""
                    headers["attach"] = prev.isEmpty ? extra : prev + ", " + extra
                }
            } else if !current.isEmpty {
                headers[current] = ((headers[current] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
            }
        }
        spec.to = splitAddrs(headers["to"] ?? "")
        spec.cc = splitAddrs(headers["cc"] ?? "")
        spec.from = headers["from"] ?? ""
        spec.subject = (headers["subject"] ?? "").trimmingCharacters(in: .whitespaces)
        spec.inReplyTo = (headers["in-reply-to"] ?? headers["reply-to-message-id"] ?? "").trimmingCharacters(in: .whitespaces)
        spec.replyMode = (headers["reply"] ?? "auto").trimmingCharacters(in: .whitespaces).lowercased()
        spec.format = (headers["format"] ?? "markdown").trimmingCharacters(in: .whitespaces).lowercased()
        spec.attach = splitAttach(headers["attach"] ?? "")
        spec.body = body.trimmingCharacters(in: CharacterSet.newlines)
        return spec
    }

    static func splitAddrs(_ raw: String) -> [String] {
        var parts: [String] = []
        var buf = ""
        var quotes = false
        var angle = 0
        for ch in raw {
            if ch == "\"" && angle == 0 { quotes.toggle(); buf.append(ch); continue }
            if !quotes {
                if ch == "<" { angle += 1 }
                else if ch == ">" && angle > 0 { angle -= 1 }
                else if ch == "," && angle == 0 {
                    let piece = buf.trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { parts.append(piece) }
                    buf = ""
                    continue
                }
            }
            buf.append(ch)
        }
        let last = buf.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    static func splitAttach(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func projectRoot(md: URL) -> URL {
        var p = md.deletingLastPathComponent()
        if p.lastPathComponent == "Drafts" { p.deleteLastPathComponent() }
        if p.lastPathComponent == "Email" { p.deleteLastPathComponent() }
        return p
    }

    static func resolveAttach(_ spec: Spec, md: URL) throws -> [URL] {
        let project = projectRoot(md: md).standardizedFileURL
        let mdDir = md.deletingLastPathComponent().standardizedFileURL
        var out: [URL] = []
        for raw in spec.attach {
            if raw.contains("..") && !raw.hasPrefix("/") {
                let probe = project.appendingPathComponent(raw).standardizedFileURL
                if !probe.path.hasPrefix(project.path + "/") && probe.path != project.path {
                    throw failure("attachment path must stay inside the project folder: \(raw)")
                }
            }
            let expanded = (raw as NSString).expandingTildeInPath
            let candidates: [URL]
            if expanded.hasPrefix("/") || raw.hasPrefix("~") {
                candidates = [URL(fileURLWithPath: expanded).standardizedFileURL]
            } else {
                candidates = [
                    project.appendingPathComponent(expanded).standardizedFileURL,
                    mdDir.appendingPathComponent(expanded).standardizedFileURL,
                ]
            }
            var inside: [URL] = []
            for c in candidates {
                if c.path == project.path || c.path.hasPrefix(project.path + "/") {
                    inside.append(c)
                }
            }
            guard !inside.isEmpty else {
                throw failure("attachment path must stay inside the project folder: \(raw)")
            }
            guard let hit = inside.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw failure("attachment not found: \(raw)")
            }
            out.append(hit)
        }
        return out
    }

    static func build(spec: Spec, md: URL) throws -> Built {
        let files = try resolveAttach(spec, md: md)
        let original = findOriginal(project: projectRoot(md: md), messageID: spec.inReplyTo)
        if original == nil && spec.replyMode != "new" {
            throw failure("No exported .eml in Email/ matches In-Reply-To. Refusing to invent a quote.")
        }
        let quote = original.map { quoteBlock($0) } ?? Quote(html: "", plain: "", references: [], from: "", date: "")
        let bodyHTML = spec.format == "plain" ? plainHTML(spec.body) : mdToHTML(spec.body)
        let cids = files.map { _ in UUID().uuidString.uppercased() }
        let chips = cids.map {
            "<span class=\"Apple-string-attachment\"><object type=\"application/x-apple-msg-attachment\" width=\"100\" data=\"cid:\($0)\"></object></span>"
        }.joined()
        let html = "<html aria-label=\"message body\"><head></head><body dir=\"auto\" style=\"overflow-wrap: break-word; -webkit-nbsp-mode: space; line-break: after-white-space;\">"
            + bodyHTML + "<div><br></div><div>" + chips + "</div>" + quote.html + "</body></html>"
        let plain = spec.body + quote.plain
        let bAlt = "Apple-Mail=_" + UUID().uuidString.uppercased()
        let bRel = "Apple-Mail=_" + UUID().uuidString.uppercased()
        var refs = quote.references
        if !spec.inReplyTo.isEmpty && !refs.contains(spec.inReplyTo) { refs.append(spec.inReplyTo) }
        var lines: [String] = []
        func hdr(_ k: String, _ v: String) { if !v.isEmpty { lines.append("\(k): \(v)") } }
        hdr("Subject", encodedHeader(spec.subject))
        lines.append("Mime-Version: 1.0 (Mac OS X Mail 16.0 \\(3901.100.1.1.11\\))")
        lines.append("Content-Type: multipart/alternative;\r\n\tboundary=\"\(bAlt)\"")
        lines.append("X-Universally-Unique-Identifier: \(UUID().uuidString.uppercased())")
        lines.append("X-Apple-Mail-Remote-Attachments: YES")
        hdr("From", encodeAddress(spec.from))
        hdr("In-Reply-To", spec.inReplyTo)
        lines.append("X-Apple-Windows-Friendly: 1")
        hdr("Date", rfc2822(Date()))
        hdr("Cc", spec.cc.map(encodeAddress).joined(separator: ", "))
        lines.append("X-Apple-Mail-Signature: ")
        let messageID = "<\(UUID().uuidString.uppercased())@me.com>"
        lines.append("Message-Id: \(messageID)")
        if !refs.isEmpty { lines.append("References: " + refs.joined(separator: "\r\n ")) }
        lines.append("X-Uniform-Type-Identifier: com.apple.mail-draft")
        hdr("To", spec.to.map(encodeAddress).joined(separator: ", "))
        var text = lines.joined(separator: "\r\n") + "\r\n\r\n"
        text += "\r\n--\(bAlt)\r\nContent-Transfer-Encoding: quoted-printable\r\nContent-Type: text/plain;\r\n\tcharset=utf-8\r\n\r\n"
        text += quotedPrintable(Data(plain.utf8)) + "\r\n"
        text += "\r\n--\(bAlt)\r\nContent-Type: multipart/related;\r\n\ttype=\"text/html\";\r\n\tboundary=\"\(bRel)\"\r\n\r\n"
        text += "\r\n--\(bRel)\r\nContent-Transfer-Encoding: quoted-printable\r\nContent-Type: text/html;\r\n\tcharset=utf-8\r\n\r\n"
        text += quotedPrintable(Data(html.utf8)) + "\r\n"
        var data = Data(text.utf8)
        for (file, cid) in zip(files, cids) {
            let name = file.lastPathComponent
            let ctype = mimeType(name)
            let part = "\r\n--\(bRel)\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: inline;\r\n\tfilename=\"\(name)\"\r\n"
                + "Content-Type: \(ctype);\r\n\tx-unix-mode=0644;\r\n\tname=\"\(name)\"\r\nContent-Id: <\(cid)>\r\n\r\n"
            data.append(Data(part.utf8))
            data.append(Data(base64Lines(try Data(contentsOf: file)).utf8))
        }
        data.append(Data("\r\n--\(bRel)--\r\n\r\n--\(bAlt)--\r\n".utf8))
        let needle = bodyNeedle(spec.body)
        return Built(
            mime: data,
            requested: spec.attach.count,
            messageID: String(messageID.dropFirst().dropLast()),
            inReplyTo: spec.inReplyTo,
            replyMode: spec.replyMode,
            subject: spec.subject,
            plainBody: spec.body,
            bodyNeedle: needle,
            quoteNeedle: quote.needle,
            wantsBold: spec.format != "plain" && spec.body.contains("**"),
            wantsList: spec.format != "plain" && (spec.body.contains("\n- ") || spec.body.hasPrefix("- ") || spec.body.contains("\n* ")),
            fromAddress: bareAddress(spec.from)
        )
    }

    struct Quote {
        var html: String
        var plain: String
        var references: [String]
        var from: String
        var date: String
        var needle: String { from.isEmpty ? "" : (from.contains(" ") ? String(from.split(separator: " ").first ?? "") : "") }
    }

    static func findOriginal(project: URL, messageID: String) -> URL? {
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !bare.isEmpty else { return nil }
        let email = project.appendingPathComponent("Email")
        let files = ((try? FileManager.default.contentsOfDirectory(at: email, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "eml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var best: URL?
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = handle.readData(ofLength: 65536)
            try? handle.close()
            guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1),
                  text.contains(bare) else { continue }
            if messageIDEquals(file, bare: bare) { best = file }
        }
        return best
    }

    static func messageIDEquals(_ file: URL, bare: String) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        let text = String(data: data.prefix(65536), encoding: .utf8) ?? String(data: data.prefix(65536), encoding: .isoLatin1) ?? ""
        let flat = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let end = flat.range(of: "\n\n") else { return false }
        var current = ""
        var value = ""
        for line in flat[..<end.lowerBound].components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let c = line.firstIndex(of: ":") {
                if current.lowercased() == "message-id" {
                    return value.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) == bare
                }
                current = String(line[..<c])
                value = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        if current.lowercased() == "message-id" {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) == bare
        }
        return false
    }

    static func quoteBlock(_ file: URL) -> Quote {
        let msg = MIME(file)
        let htmlPart = msg.firstText("text/html")
        let plainPart = msg.firstText("text/plain")
        let from = msg.header("From")
        let dateRaw = msg.header("Date")
        let when: String
        if let date = parseMailDate(dateRaw) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "d MMM yyyy, 'at' HH:mm"
            when = f.string(from: date)
        } else {
            when = ""
        }
        let attribution = "On \(when), \(from) wrote:"
        var body = htmlPart ?? ("<pre>" + escapeHTML(plainPart ?? "") + "</pre>")
        if let range = body.range(of: "<body[^>]*>(.*)</body>", options: [.regularExpression, .caseInsensitive]) {
            let inner = String(body[range])
            if let open = inner.range(of: ">", options: []), let close = inner.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                body = String(inner[open.upperBound..<close.lowerBound])
            }
        }
        body = body.replacingOccurrences(of: "<img[^>]*src=\"cid:[^\"]*\"[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<(script|style)[^>]*>.*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        let qHTML = "<div><br></div><div>" + escapeHTML(attribution) + "</div><br class=\"Apple-interchange-newline\"><blockquote type=\"cite\">" + body + "</blockquote>"
        let qPlain = "\n\n" + attribution + "\n\n" + (plainPart ?? "").components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let refs = msg.header("References").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let needle = attribution.contains("wrote:") ? "wrote:" : ""
        var q = Quote(html: qHTML, plain: qPlain, references: refs, from: from, date: dateRaw)
        if !needle.isEmpty {
            // Prefer a token from the real sender so the check is the quote, not our own text.
            let name = from.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if name.count >= 3 { q.from = name }
        }
        return q
    }

    static func mdToHTML(_ md: String) -> String {
        func inline(_ t: String) -> String {
            let parts = t.components(separatedBy: "**")
            var out = ""
            for (i, p) in parts.enumerated() {
                if i % 2 == 1 && i < parts.count - 1 {
                    out += "<b>" + escapeHTML(p) + "</b>"
                } else if i % 2 == 1 && i == parts.count - 1 {
                    out += "**" + escapeHTML(p)
                } else {
                    out += escapeHTML(p)
                }
            }
            return out
        }
        // Match the Python splitter: **bold** via regex, not a naive split (odd asterisks).
        func inlineRE(_ t: String) -> String {
            var out = ""
            var rest = t
            while let start = rest.range(of: "**") {
                out += escapeHTML(String(rest[..<start.lowerBound]))
                let after = rest[start.upperBound...]
                if let end = after.range(of: "**"), end.lowerBound > after.startIndex {
                    out += "<b>" + escapeHTML(String(after[..<end.lowerBound])) + "</b>"
                    rest = String(after[end.upperBound...])
                } else {
                    out += "**"
                    rest = String(after)
                    break
                }
            }
            out += escapeHTML(rest)
            return out
        }
        _ = inline
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if lines[i].range(of: #"^\s*[-*]\s+"#, options: .regularExpression) != nil {
                var items: [String] = []
                while i < lines.count, lines[i].range(of: #"^\s*[-*]\s+"#, options: .regularExpression) != nil {
                    let item = lines[i].replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression)
                    items.append("<li>" + inlineRE(item.trimmingCharacters(in: .whitespaces)) + "</li>")
                    i += 1
                }
                blocks.append("<ul>" + items.joined() + "</ul>")
                continue
            }
            var para: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                  lines[i].range(of: #"^\s*[-*]\s+"#, options: .regularExpression) == nil {
                para.append(lines[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            blocks.append("<div>" + para.map(inlineRE).joined(separator: "<br>") + "</div>")
        }
        return blocks.joined(separator: "<div><br></div>")
    }

    static func bodyNeedle(_ body: String) -> String {
        let line = body.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let plain = line.replacingOccurrences(of: "**", with: "")
        return String(plain.prefix(40))
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func plainHTML(_ body: String) -> String {
        "<div>" + escapeHTML(body).replacingOccurrences(of: "\n", with: "<br>") + "</div>"
    }

    /// RFC 2047 Q-encoding. ASCII text is left as-is. Non-ASCII is never replaced.
    static func encodedHeader(_ value: String) -> String {
        if value.utf8.allSatisfy({ $0 < 128 }) { return value }
        return encodedWords(value)
    }

    static func encodeAddress(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let open = trimmed.lastIndex(of: "<"),
              let close = trimmed.lastIndex(of: ">"),
              open < close else {
            return encodedHeader(trimmed)
        }
        var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        let email = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        if name.isEmpty { return "<\(email)>" }
        if name.utf8.contains(where: { $0 >= 128 }) {
            return "\(encodedWords(name)) <\(email)>"
        }
        return "\(name) <\(email)>"
    }

    static func encodedWords(_ value: String) -> String {
        let prefix = "=?UTF-8?Q?"
        let suffix = "?="
        let budget = 75 - prefix.count - suffix.count
        var words: [String] = []
        var chunk = ""
        func flush() {
            if !chunk.isEmpty {
                words.append(prefix + chunk + suffix)
                chunk = ""
            }
        }
        for byte in value.utf8 {
            let token: String
            if byte == 0x20 {
                token = "_"
            } else if byte >= 33 && byte <= 126 && byte != 0x3D && byte != 0x3F && byte != 0x5F {
                token = String(UnicodeScalar(byte))
            } else {
                token = String(format: "=%02X", byte)
            }
            if chunk.utf8.count + token.utf8.count > budget {
                flush()
            }
            chunk += token
        }
        flush()
        return words.joined(separator: "\r\n ")
    }

    static func decodeWords(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let glue = try? NSRegularExpression(pattern: #"\?=[\t ]+=\?"#)
        // Remove whitespace that sits between two encoded-words.
        if let glue {
            let range = NSRange(text.startIndex..., in: text)
            text = glue.stringByReplacingMatches(in: text, range: range, withTemplate: "?==?")
        }
        let word = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#)
        guard let word else { return value }
        var out = ""
        var cursor = text.startIndex
        let ns = text as NSString
        let matches = word.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if matches.isEmpty { return value }
        for match in matches {
            guard let full = Range(match.range, in: text),
                  let encRange = Range(match.range(at: 2), in: text),
                  let dataRange = Range(match.range(at: 3), in: text) else { continue }
            out += String(text[cursor..<full.lowerBound])
            let enc = String(text[encRange])
            let payload = String(text[dataRange])
            let bytes: Data
            if enc.uppercased() == "B" {
                bytes = Data(base64Encoded: payload) ?? Data()
            } else {
                bytes = decodeQ(payload)
            }
            out += String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
            cursor = full.upperBound
            _ = ns
        }
        out += String(text[cursor...])
        return out
    }

    static func decodeQ(_ payload: String) -> Data {
        var out = Data()
        let bytes = Array(payload.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x5F {
                out.append(0x20)
                i += 1
            } else if bytes[i] == 0x3D, i + 2 < bytes.count,
                      let v = UInt8(String(bytes: [bytes[i + 1], bytes[i + 2]], encoding: .ascii) ?? "", radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    static func quotedPrintable(_ data: Data) -> String {
        let bytes = [UInt8](data)
        func hex(_ n: UInt8) -> UInt8 { Array("0123456789ABCDEF".utf8)[Int(n)] }
        func quote(_ c: UInt8) -> [UInt8] { [0x3D, hex(c >> 4), hex(c & 15)] }
        func needs(_ c: UInt8) -> Bool {
            if c == 9 || c == 32 { return false }
            if c == 0x3D { return true }
            return !(c >= 32 && c <= 126)
        }
        var output = Data()
        var i = 0
        while i < bytes.count {
            var line: [UInt8] = []
            var hadNL = false
            while i < bytes.count && bytes[i] != 10 {
                line.append(bytes[i]); i += 1
            }
            if i < bytes.count && bytes[i] == 10 { hadNL = true; i += 1 }
            var encoded = Data()
            for c in line {
                if needs(c) { encoded.append(contentsOf: quote(c)) } else { encoded.append(c) }
            }
            func write(_ chunk: Data, end: [UInt8]) {
                var s = chunk
                if let last = s.last, last == 32 || last == 9 {
                    s.removeLast()
                    s.append(contentsOf: quote(last))
                } else if s == Data([0x2E]) {
                    s = Data(quote(0x2E))
                }
                output.append(s)
                output.append(contentsOf: end)
            }
            while encoded.count > 76 {
                var cut = min(75, encoded.count)
                let bytes = [UInt8](encoded)
                if cut > 0 && cut < bytes.count {
                    if bytes[cut - 1] == 0x3D {
                        cut -= 1
                    } else if cut >= 2 && bytes[cut - 2] == 0x3D {
                        cut -= 2
                    }
                }
                if cut <= 0 { cut = min(75, encoded.count) }
                write(encoded.prefix(cut), end: [0x3D, 0x0D, 0x0A])
                encoded = Data(encoded.dropFirst(cut))
            }
            write(encoded, end: hadNL ? [0x0A] : [])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func base64Lines(_ data: Data) -> String {
        var s = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        if !s.hasSuffix("\n") { s += "\n" }
        return s.replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }

    static func rfc2822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    static func parseMailDate(_ s: String) -> Date? {
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss z",
        ]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }

    // MARK: - Upload

    enum Upload {
        case uploaded(uid: Int, connect: Double, append: Double, raw: Data?)
        case offline
        case failed(String)
    }

    static func upload(mime: Data, user: String, password: String) -> Upload {
        let t0 = Date()
        let session = IMAP()
        guard session.connect(timeout: 3) else {
            session.close()
            return .offline
        }
        let connect = elapsed(t0)
        guard session.authenticate(user: user, password: password) else {
            let err = session.last
            session.close()
            return .failed(err.isEmpty ? "IMAP login failed" : err)
        }
        let t1 = Date()
        guard let uid = session.appendDraft(mime) else {
            let err = session.last
            session.close()
            return .failed(err.isEmpty ? "IMAP append failed" : err)
        }
        let append = elapsed(t1)
        let raw = session.fetchBody(uid: uid)
        session.close()
        return .uploaded(uid: uid, connect: connect, append: append, raw: raw)
    }

    // MARK: - Import

    struct Imported {
        var importSeconds: Double
        var moveSeconds: Double
        var leftover: String
        var error: String?
    }

    static func importDraft(_ built: Built) -> Imported {
        let name = "MailExporter-\(UUID().uuidString.prefix(8))"
        let box = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mbox", isDirectory: true)
        let messages = box.appendingPathComponent("Messages", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
            var lf = built.mime
            if let text = String(data: built.mime, encoding: .utf8) {
                lf = Data(text.replacingOccurrences(of: "\r\n", with: "\n").utf8)
            }
            let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>flags</key>\n\t<integer>8590132289</integer>\n</dict>\n</plist>\n"
            var file = Data("\(lf.count)\n".utf8)
            file.append(lf)
            file.append(Data("\n".utf8))
            file.append(Data(plist.utf8))
            try file.write(to: messages.appendingPathComponent("1.emlx"))
        } catch {
            return Imported(importSeconds: 0, moveSeconds: 0, leftover: "", error: error.localizedDescription)
        }
        let t1 = Date()
        let imp = osa("tell application \"Mail\" to import Mail mailbox at POSIX file \"\(esc(box.path))\"")
        let importSeconds = elapsed(t1)
        guard imp.ok else {
            try? FileManager.default.removeItem(at: box)
            return Imported(importSeconds: importSeconds, moveSeconds: 0, leftover: name, error: imp.text)
        }
        let t2 = Date()
        let moved = osa(moveScript(name: name, id: built.messageID, address: built.fromAddress))
        let moveSeconds = elapsed(t2)
        try? FileManager.default.removeItem(at: box)
        if !moved.ok || moved.text.hasPrefix("ERROR") {
            return Imported(importSeconds: importSeconds, moveSeconds: moveSeconds, leftover: name, error: moved.text)
        }
        let parent = moved.text.components(separatedBy: "parent=").dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let leftover = parent.isEmpty ? name : "\(parent)/\(name)"
        return Imported(importSeconds: importSeconds, moveSeconds: moveSeconds, leftover: leftover, error: nil)
    }

    static func moveScript(name: String, id: String, address: String) -> String {
        """
        tell application "Mail"
            set acct to missing value
            repeat with a in accounts
                try
                    if (email addresses of a) contains "\(esc(address))" then set acct to a
                end try
            end repeat
            if acct is missing value then return "ERROR no account"
            set dst to missing value
            repeat with b in mailboxes of acct
                if name of b is "Drafts" then set dst to b
            end repeat
            if dst is missing value then return "ERROR no Drafts mailbox"
            set found to missing value
            set srcBox to missing value
            repeat with mb in mailboxes
                try
                    if name of mb is "\(esc(name))" then
                        set srcBox to mb
                        set hits to (messages of mb whose message id is "\(esc(id))")
                        if (count of hits) > 0 then set found to item 1 of hits
                    end if
                end try
                if found is not missing value then exit repeat
            end repeat
            if found is missing value then
                repeat with mb in mailboxes
                    repeat with sub in mailboxes of mb
                        try
                            if name of sub is "\(esc(name))" then
                                set srcBox to sub
                                set hits to (messages of sub whose message id is "\(esc(id))")
                                if (count of hits) > 0 then set found to item 1 of hits
                            end if
                        end try
                        if found is not missing value then exit repeat
                    end repeat
                    if found is not missing value then exit repeat
                end repeat
            end if
            if found is missing value then return "ERROR imported message not found"
            set parentName to ""
            try
                set parentName to name of container of srcBox
            end try
            move found to dst
            return "moved parent=" & parentName
        end tell
        """
    }

    // MARK: - Verify

    struct ReadBack {
        var found: Bool
        var attached: Int
        var cids: Int
        var names: [String]
        var to: String
        var cc: String
        var subject: String
        var row: String
        var hasBody: Bool
        var hasQuote: Bool
        var rawStars: Bool
        var hasBold: Bool
        var hasList: Bool
        var inReply: Bool
        var wait: Double
        var error: String
    }

    static func verify(_ built: Built, seconds: inout [String: Double]) -> ReadBack {
        let t0 = Date()
        let deadline = Date().addingTimeInterval(30)
        var last = ""
        while Date() < deadline {
            let r = osa(verifyScript(built))
            last = r.text
            if r.ok && !r.text.hasPrefix("WAIT") && !r.text.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        var read = ReadBack(
            found: false, attached: -1, cids: -1, names: [], to: "", cc: "", subject: "",
            row: "", hasBody: false, hasQuote: false, rawStars: false, hasBold: false,
            hasList: false, inReply: false, wait: elapsed(t0), error: ""
        )
        if last.hasPrefix("WAIT") || last.isEmpty {
            read.error = "Mail did not show the draft within 30 seconds"
            return read
        }
        let fields = parseFields(last)
        read.found = true
        read.attached = Int(fields["attachments"] ?? "") ?? -1
        read.cids = Int(fields["cids"] ?? "") ?? -1
        read.names = (fields["names"] ?? "").split(separator: "|").map(String.init).filter { !$0.isEmpty }
        read.to = fields["to"] ?? ""
        read.cc = fields["cc"] ?? ""
        read.subject = fields["subject"] ?? ""
        read.row = fields["rowid"] ?? ""
        read.hasBody = fields["hasBody"] == "true"
        read.hasQuote = fields["hasQuote"] == "true"
        read.rawStars = fields["rawStars"] == "true"
        read.hasBold = fields["srcB"] == "true"
        read.hasList = fields["srcUL"] == "true"
        read.inReply = fields["inReplyTo"] == "1"
        return read
    }

    static func verifyScript(_ built: Built) -> String {
        let quote = built.quoteNeedle.isEmpty ? "wrote:" : built.quoteNeedle
        return """
        tell application "Mail"
            set acct to missing value
            repeat with a in accounts
                try
                    if (email addresses of a) contains "\(esc(built.fromAddress))" then set acct to a
                end try
            end repeat
            if acct is missing value then return "WAIT"
            set hits to (messages of (mailbox "Drafts" of acct) whose message id is "\(esc(built.messageID))")
            if (count of hits) = 0 then return "WAIT"
            set d to item 1 of hits
            set names to ""
            repeat with a in mail attachments of d
                set names to names & (name of a) & "|"
            end repeat
            set c to content of d as text
            set src to source of d
            set AppleScript's text item delimiters to "Content-Id: <"
            set cids to (count of text items of src) - 1
            set AppleScript's text item delimiters to ""
            set hdrs to all headers of d
            set irt to "0"
            if hdrs contains "In-Reply-To:" and hdrs contains "\(esc(built.inReplyTo))" then set irt to "1"
            return "attachments=" & (count of mail attachments of d) & linefeed & "names=" & names & linefeed & "cids=" & cids & linefeed & "hasBody=" & (c contains "\(esc(built.bodyNeedle))") & linefeed & "hasQuote=" & (c contains "\(esc(quote))") & linefeed & "rawStars=" & (c contains "**") & linefeed & "srcUL=" & (src contains "<ul>") & linefeed & "srcB=" & (src contains "<b>") & linefeed & "to=" & (address of every to recipient of d as text) & linefeed & "cc=" & (address of every cc recipient of d as text) & linefeed & "subject=" & (subject of d) & linefeed & "inReplyTo=" & irt & linefeed & "rowid=" & (id of d)
        end tell
        """
    }

    static func verifyFields(_ read: ReadBack, built: Built, leftover: String) -> [String: Any] {
        let formatting = !read.rawStars && (!built.wantsBold || read.hasBold) && (!built.wantsList || read.hasList)
        let quoteOK = built.quoteNeedle.isEmpty ? true : read.hasQuote
        let countOK = read.attached == built.requested && read.cids == built.requested
        let needsReply = built.replyMode == "reply" || built.replyMode == "reply-all"
        let ok = read.found && countOK
        var result = "attached \(read.attached) of \(built.requested)"
        if !countOK { result += " (WRONG COUNT)" }
        var err = read.error
        if read.found && !countOK { err = append(err, "attachment count does not match") }
        var warnings: [String] = []
        if read.found && !read.hasBody { warnings.append("body words missing") }
        if read.found && read.rawStars { warnings.append("raw markdown remains") }
        if read.found && needsReply && !read.inReply { warnings.append("In-Reply-To missing") }
        if read.found && !quoteOK { warnings.append("quote missing") }
        if read.found && !formatting { warnings.append("formatting missing") }
        return [
            "ok": ok,
            "result": result,
            "attached": read.attached,
            "requested": built.requested,
            "names": read.names,
            "to": read.to,
            "cc": read.cc,
            "subject": read.subject,
            "inReplyToPresent": read.inReply,
            "quote": read.hasQuote,
            "formatting": formatting,
            "draftRowID": read.row,
            "leftoverMailbox": leftover,
            "warnings": warnings,
            "error": err,
        ]
    }

    static func fieldsFromUpload(built: Built, raw: Data?) -> [String: Any] {
        var warnings: [String] = []
        guard let raw, !raw.isEmpty else {
            warnings.append("Could not read the draft back from the server")
            return [
                "ok": true,
                "result": "attached \(built.requested) of \(built.requested)",
                "attached": built.requested,
                "requested": built.requested,
                "subject": built.subject,
                "inReplyToPresent": false,
                "warnings": warnings,
                "error": "",
            ]
        }
        let mime = MIME(String(decoding: raw, as: UTF8.self))
        let subject = decodeWords(mime.header("Subject"))
        let attached = filenameCount(raw)
        let countOK = attached == built.requested
        let plain = (mime.firstText("text/plain") ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
        let expected = built.plainBody
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
        if plain != expected { warnings.append("body text differs") }
        let needsReply = built.replyMode == "reply" || built.replyMode == "reply-all"
        let headerReply = mime.header("In-Reply-To")
        let present = !built.inReplyTo.isEmpty && headerReply.contains(built.inReplyTo)
        if needsReply && !present { warnings.append("In-Reply-To missing") }
        return [
            "ok": countOK,
            "result": "attached \(attached) of \(built.requested)",
            "attached": attached,
            "requested": built.requested,
            "subject": subject,
            "inReplyToPresent": present || !needsReply,
            "warnings": warnings,
            "error": countOK ? "" : "attachment count does not match",
        ]
    }

    static func filenameCount(_ raw: Data) -> Int {
        let text = String(decoding: raw, as: UTF8.self)
        return text.components(separatedBy: "filename=\"").count - 1
    }

    // MARK: - Mail helpers

    static func ensureMail() {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.mail" }
        if !running {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-a", "Mail"]
            try? p.run()
            p.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let r = osa("tell application \"Mail\" to get name")
            if r.ok && r.text == "Mail" { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    static func accountType(address: String) -> String {
        let r = osa("""
        tell application "Mail"
            repeat with a in accounts
                try
                    if (email addresses of a) contains "\(esc(address))" then return (account type of a as text)
                end try
            end repeat
            return "missing"
        end tell
        """)
        return r.ok ? r.text : "missing"
    }

    static func keychainPassword(account: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return pw.isEmpty ? nil : pw
    }

    static func osa(_ source: String) -> (ok: Bool, text: String) {
        if source.range(of: #"\bsend\b"#, options: .regularExpression) != nil {
            return (false, "refused: script contains send")
        }
        let work = { () -> (Bool, String) in
            var err: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return (false, "could not compile") }
            let result = script.executeAndReturnError(&err)
            if let err {
                let message = err[NSAppleScript.errorMessage] as? String ?? err.description
                return (false, message)
            }
            return (true, result.stringValue ?? "")
        }
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    static func mailWindowCount() -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return -1
        }
        return list.filter { ($0[kCGWindowOwnerName as String] as? String) == "Mail" }.count
    }

    static func frontmost() -> String {
        let read = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }
        if Thread.isMainThread { return read() }
        return DispatchQueue.main.sync(execute: read)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func bareAddress(_ s: String) -> String {
        if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
            return String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func elapsed(_ start: Date) -> Double {
        (Date().timeIntervalSince(start) * 100).rounded() / 100
    }

    static func parseFields(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    static func append(_ a: String, _ b: String) -> String { a.isEmpty ? b : a + " " + b }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "MailExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

private extension String {
    func lstripNewlines() -> String {
        var s = self
        while s.first == "\n" || s.first == "\r" { s.removeFirst() }
        return s
    }
}

/// IMAP APPEND only. No SMTP. No command that sends mail.
private final class IMAP {
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "MailExporter.imap")
    private var buffer = Data()
    private let lock = NSLock()
    var last = ""
    private var sendNote = ""

    func connect(timeout: TimeInterval) -> Bool {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls)
        let c = NWConnection(host: NWEndpoint.Host(HiddenDraft.host), port: NWEndpoint.Port(rawValue: HiddenDraft.port)!, using: params)
        conn = c
        let ready = DispatchSemaphore(value: 0)
        let box = Box(false)
        c.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.value = true
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        c.start(queue: queue)
        _ = ready.wait(timeout: .now() + timeout)
        guard box.value else { return false }
        receive()
        let greet = readNew(from: 0, timeout: 3) { $0.contains("* OK") || $0.contains(" OK") }
        return greet.contains("OK")
    }

    func authenticate(user: String, password: String) -> Bool {
        var token = Data([0])
        token.append(Data(user.utf8))
        token.append(Data([0]))
        token.append(Data(password.utf8))
        let b64 = token.base64EncodedString()
        let start = bufferedCount()
        sendRaw(Data(("A1 AUTHENTICATE PLAIN \(b64)\r\n").utf8))
        let reply = readNew(from: start, timeout: 15) { text in
            text.contains("A1 OK") || text.contains("A1 NO") || text.contains("A1 BAD")
        }
        last = reply
        return reply.contains("A1 OK")
    }

    func appendDraft(_ mime: Data) -> Int? {
        let line = "A2 APPEND Drafts (\\Seen \\Draft) {\(mime.count)}"
        let ask = command(line, timeout: 15)
        guard ask.contains("+") else {
            last = ask.isEmpty ? "no continuation \(sendNote)" : ask
            return nil
        }
        let start = bufferedCount()
        sendRaw(mime)
        sendRaw(Data("\r\n".utf8))
        let reply = readNew(from: start, timeout: 20) { $0.contains("A2 OK") || $0.contains("A2 NO") || $0.contains("A2 BAD") }
        last = reply
        guard reply.contains("A2 OK") else { return nil }
        if let r = reply.range(of: #"APPENDUID \d+ (\d+)"#, options: .regularExpression) {
            let s = String(reply[r])
            if let n = s.split(separator: " ").last, let uid = Int(n) { return uid }
        }
        return 0
    }

    func fetchBody(uid: Int) -> Data? {
        guard uid > 0 else { return nil }
        let selected = command("A3 SELECT Drafts", timeout: 15)
        guard selected.contains("A3 OK") else {
            last = selected
            return nil
        }
        let start = bufferedCount()
        sendRaw(Data("A4 UID FETCH \(uid) (BODY.PEEK[])\r\n".utf8))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            lock.lock()
            let slice = buffer.count > start ? buffer.subdata(in: start..<buffer.count) : Data()
            lock.unlock()
            if let body = Self.literalBody(slice),
               slice.range(of: Data("A4 OK".utf8)) != nil
                || slice.range(of: Data("A4 NO".utf8)) != nil
                || slice.range(of: Data("A4 BAD".utf8)) != nil {
                return body
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock()
        let slice = buffer.count > start ? buffer.subdata(in: start..<buffer.count) : Data()
        lock.unlock()
        last = String(decoding: slice, as: UTF8.self)
        return Self.literalBody(slice)
    }

    static func literalBody(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "{") {
                var j = i + 1
                var n = 0
                var digits = false
                while j < bytes.count, bytes[j] >= 48, bytes[j] <= 57 {
                    digits = true
                    n = n * 10 + Int(bytes[j] - 48)
                    j += 1
                }
                if digits, j + 1 < bytes.count, bytes[j] == 13, bytes[j + 1] == 10 {
                    let start = j + 2
                    if start + n <= bytes.count {
                        return Data(bytes[start..<(start + n)])
                    }
                    return nil
                }
            }
            i += 1
        }
        return nil
    }

    func close() {
        _ = command("A5 LOGOUT", timeout: 3)
        conn?.cancel()
    }

    private func command(_ line: String, timeout: TimeInterval) -> String {
        let start = bufferedCount()
        sendRaw(Data((line + "\r\n").utf8))
        return readNew(from: start, timeout: timeout) { text in
            text.contains("+") || text.contains(" OK") || text.contains(" NO") || text.contains(" BAD")
        }
    }

    private func bufferedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    private func sendRaw(_ data: Data) {
        let sem = DispatchSemaphore(value: 0)
        conn?.send(content: data, completion: .contentProcessed { error in
            if let error { self.sendNote = String(describing: error) }
            sem.signal()
        })
        _ = sem.wait(timeout: .now() + 10)
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                self.lock.lock()
                self.buffer.append(data)
                self.lock.unlock()
            }
            if error == nil && !isComplete { self.receive() }
        }
    }

    private func readNew(from start: Int, timeout: TimeInterval, ready: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let slice = buffer.count > start ? buffer.subdata(in: start..<buffer.count) : Data()
            lock.unlock()
            let text = String(decoding: slice, as: UTF8.self)
            if ready(text) { return text }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock()
        let slice = buffer.count > start ? buffer.subdata(in: start..<buffer.count) : Data()
        lock.unlock()
        return String(decoding: slice, as: UTF8.self)
    }
}

/// Walks one exported message far enough to read its text parts.
private struct MIME {
    var headers: [(String, String)] = []
    var body = ""
    var children: [MIME] = []

    init(_ url: URL) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        self.init(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n"))
    }

    init(_ text: String) {
        let split = text.range(of: "\n\n")
        let head = split.map { String(text[..<$0.lowerBound]) } ?? text
        let rest = split.map { String(text[$0.upperBound...]) } ?? ""
        for line in head.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !headers.isEmpty {
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let c = line.firstIndex(of: ":") {
                headers.append((String(line[..<c]), line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        body = rest
        let ct = header("Content-Type")
        if ct.lowercased().hasPrefix("multipart"),
           let r = ct.range(of: "boundary=\"?([^\";]+)\"?", options: .regularExpression) {
            var b = String(ct[r])
            if let eq = b.firstIndex(of: "=") { b = String(b[b.index(after: eq)...]) }
            b = b.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            for piece in rest.components(separatedBy: "--\(b)").dropFirst() where !piece.hasPrefix("--") {
                var p = piece
                if p.hasPrefix("\n") { p.removeFirst() }
                children.append(MIME(p))
            }
        }
    }

    func header(_ name: String) -> String {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 ?? ""
    }

    func firstText(_ type: String) -> String? {
        let ct = header("Content-Type").lowercased()
        if children.isEmpty {
            if ct.hasPrefix(type), !header("Content-Disposition").lowercased().hasPrefix("attachment") {
                return decoded()
            }
            return nil
        }
        for c in children {
            if let t = c.firstText(type) { return t }
        }
        return nil
    }

    func decoded() -> String {
        let enc = header("Content-Transfer-Encoding").lowercased()
        let data: Data
        if enc.contains("base64") {
            let clean = body.components(separatedBy: .whitespacesAndNewlines).joined()
            data = Data(base64Encoded: clean) ?? Data()
        } else if enc.contains("quoted-printable") {
            data = qpDecode(body)
        } else {
            data = Data(body.utf8)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func qpDecode(_ s: String) -> Data {
        let flat = s.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        var out = Data()
        let u = Array(flat.utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "="), i + 2 < u.count,
               let v = UInt8(String(bytes: [u[i + 1], u[i + 2]], encoding: .ascii) ?? "", radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return out
    }
}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
