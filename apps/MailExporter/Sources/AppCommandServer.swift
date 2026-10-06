import Darwin
import Foundation

/// Local socket so Cursor and Claude can ask this app to read mail.
/// The mail read happens in this app, which already has disk access.
enum AppCommandServer {
    static let socketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/MailExporter/cmd.sock"
    }()

    static func start() {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                _ = strncpy(dst, socketPath, 103)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        _ = chmod(socketPath, 0o600)

        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global(qos: .userInitiated).async {
                    handle(client)
                }
            }
        }
    }

    private static func handle(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < 1_000_000 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(n))
            if buffer.contains(0x0A) { break }
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return }
        let line = buffer.prefix(upTo: newline)
        let response: String
        do {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw NSError(domain: "MailExporter", code: 30, userInfo: [
                    NSLocalizedDescriptionKey: "Request must be a JSON object.",
                ])
            }
            let cmd = obj["cmd"] as? String ?? ""
            if cmd == "compose" {
                response = composeResponse(obj)
            } else if cmd == "create-job" || cmd == "edit-job" {
                response = try EngineSession.shared.performRaw(obj)
                DispatchQueue.main.async {
                    JobsStore.current?.reload()
                }
            } else {
                response = try EngineSession.shared.performRaw(obj)
            }
        } catch {
            let err: [String: Any] = ["ok": false, "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: err),
               let text = String(data: data, encoding: .utf8) {
                response = text
            } else {
                response = "{\"ok\":false,\"error\":\"request failed\"}"
            }
        }
        var out = Data(response.utf8)
        out.append(0x0A)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(client, base, raw.count)
        }
    }

    /// Open a Mail draft in this app. Cursor and Claude only pass the request.
    private static func composeResponse(_ obj: [String: Any]) -> String {
        let path = (obj["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let markdown = obj["markdown"] as? String ?? ""
        let fileURL: URL
        if !path.isEmpty {
            fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                return jsonLine(["ok": false, "error": "file not found: \(fileURL.path)"])
            }
        } else if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MailExporter/compose-inbox", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                fileURL = dir.appendingPathComponent("compose-\(Int(Date().timeIntervalSince1970)).md")
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                return jsonLine(["ok": false, "error": error.localizedDescription])
            }
        } else {
            return jsonLine(["ok": false, "error": "provide path or markdown"])
        }
        do {
            let result = try ComposeBridge.compose(markdownFiles: [fileURL])
            var payload: [String: Any] = [
                "ok": result.ok,
                "summary": result.summary,
                "detail": result.detail,
                "via": "app",
            ]
            if let counts = AttachCountCheck.parse(result.detail) {
                payload["attached"] = counts.attached
                payload["requested"] = counts.requested
                payload["result"] = "attached \(counts.attached) of \(counts.requested)"
            } else if result.ok {
                payload["result"] = result.summary
            } else {
                let failure = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                payload["result"] = (failure.isEmpty || failure == "OK") ? "Compose failed" : failure
            }
            if result.ok == false, (payload["result"] as? String) == "OK" {
                payload["result"] = "Compose failed"
            }
            DraftNotifier.announce(result, draftCount: 1)
            return jsonLine(payload)
        } catch {
            let failed = ComposeResult(ok: false, summary: "Compose failed", detail: error.localizedDescription)
            DraftNotifier.announce(failed, draftCount: 1)
            return jsonLine(["ok": false, "error": error.localizedDescription])
        }
    }

    private static func jsonLine(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"request failed\"}"
        }
        return text
    }
}
