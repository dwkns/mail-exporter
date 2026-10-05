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
            response = try EngineSession.shared.performRaw(obj)
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
}
