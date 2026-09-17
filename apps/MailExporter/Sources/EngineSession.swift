import Foundation

/// Long-lived `serve` worker so Check Matches → Export skips PyInstaller startup.
final class EngineSession {
    static let shared = EngineSession()

    private let queue = DispatchQueue(label: "com.dwkns.MailExporter.engine-session")
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?

    private init() {}

    func prewarm() {
        queue.async { [weak self] in
            try? self?.ensureStarted()
        }
    }

    func export(
        projectRoot: URL,
        configPath: URL,
        jobID: String?,
        dryRun: Bool,
        forceFull: Bool = false
    ) throws -> EngineResult {
        do {
            return try queue.sync {
                try ensureStarted()
                var req: [String: Any] = [
                    "cmd": "export",
                    "config": configPath.path,
                    "dryRun": dryRun,
                    "forceFull": forceFull,
                ]
                if let jobID {
                    req["jobId"] = jobID
                }
                return try sendLocked(req)
            }
        } catch {
            var args = ["export"]
            if dryRun { args.append("--dry-run") }
            if forceFull { args.append("--force-full") }
            if let jobID { args += ["--job-id", jobID] }
            return try EngineBridge.run(
                projectRoot: projectRoot,
                arguments: args,
                configPath: configPath
            )
        }
    }

    private func ensureStarted() throws {
        if let process, process.isRunning, stdin != nil, stdout != nil {
            return
        }
        stopLocked()
        let exe = try EngineBridge.engineExecutable()
        let proc = Process()
        proc.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let rg = resources.appendingPathComponent("bin/rg")
        if FileManager.default.isExecutableFile(atPath: rg.path) {
            env["MAILEXPORTER_RG"] = rg.path
            let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = "\(resources.appendingPathComponent("bin").path):\(path)"
        }
        proc.environment = env
        let isBundled = exe.lastPathComponent == "MailExporterEngine"
        if isBundled {
            proc.arguments = ["serve"]
            proc.currentDirectoryURL = exe.deletingLastPathComponent()
        } else {
            proc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            proc.arguments = ["-m", "engine_entry"] // unused; fall back below
            // Dev: python - the engine_entry serve path needs the frozen helper.
            // Spawn bundled-style isn't available; use one-shot EngineBridge instead.
            throw NSError(
                domain: "MailExporter",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Engine serve needs the bundled helper"]
            )
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        process = proc
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        stderr = errPipe.fileHandleForReading

        guard let line = try readLineLocked(timeout: 20),
              let data = line.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ready"] as? Bool == true
        else {
            stopLocked()
            throw NSError(
                domain: "MailExporter",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Engine worker did not become ready"]
            )
        }
    }

    private func sendLocked(_ req: [String: Any]) throws -> EngineResult {
        let payload = try JSONSerialization.data(withJSONObject: req)
        guard var line = String(data: payload, encoding: .utf8) else {
            throw NSError(
                domain: "MailExporter",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Couldn’t encode engine request"]
            )
        }
        line += "\n"
        guard let stdin else {
            throw NSError(
                domain: "MailExporter",
                code: 23,
                userInfo: [NSLocalizedDescriptionKey: "Engine stdin closed"]
            )
        }
        stdin.write(Data(line.utf8))
        guard let raw = try readLineLocked(timeout: 600) else {
            stopLocked()
            throw NSError(
                domain: "MailExporter",
                code: 24,
                userInfo: [NSLocalizedDescriptionKey: "Engine worker returned no response"]
            )
        }
        return try EngineBridge.parseEngineOutput(raw + "\n", status: 0, wall: 0)
    }

    private func readLineLocked(timeout: TimeInterval) throws -> String? {
        guard let stdout else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            if let process, !process.isRunning {
                return nil
            }
            let chunk = stdout.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            buffer.append(chunk)
            if let range = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                return String(data: line, encoding: .utf8)
            }
        }
        return nil
    }

    private func stopLocked() {
        stdin = nil
        stdout = nil
        stderr = nil
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
    }
}
