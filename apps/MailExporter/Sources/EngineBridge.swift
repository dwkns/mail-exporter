import Foundation

struct EngineResult: Equatable {
    var line: String
    var ok: Bool
    var rawJSON: String
    var matchCount: Int?
}

enum EngineBridge {
    /// Bundled onedir helper: …/Contents/Resources/MailExporterEngine/MailExporterEngine
    static func bundledEngineURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/MailExporterEngine/MailExporterEngine")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func engineExecutable() throws -> URL {
        if let bundled = bundledEngineURL() {
            return bundled
        }
        // Dev fallback only (unsigned / missing bundle): system Python.
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    /// Touch the engine once at launch so the first export isn’t a cold disk hit.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            guard let exe = bundledEngineURL() else { return }
            let process = Process()
            process.executableURL = exe
            process.arguments = ["list"]
            process.currentDirectoryURL = exe.deletingLastPathComponent()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    static func run(
        projectRoot: URL,
        arguments: [String],
        configPath: URL
    ) throws -> EngineResult {
        let exe = try engineExecutable()
        let process = Process()
        process.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let rg = resources.appendingPathComponent("bin/rg")
        if FileManager.default.isExecutableFile(atPath: rg.path) {
            env["MAILEXPORTER_RG"] = rg.path
            // Keep PATH minimal but include our bin so any child "rg" resolves to bundled.
            let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = "\(resources.appendingPathComponent("bin").path):\(path)"
        }
        process.environment = env

        let isBundled = exe.lastPathComponent == "MailExporterEngine"
        if isBundled {
            process.arguments = ["--config", configPath.path] + arguments
            process.currentDirectoryURL = exe.deletingLastPathComponent()
        } else {
            process.currentDirectoryURL = projectRoot
            process.arguments = ["-m", "engine", "--config", configPath.path] + arguments
        }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let t0 = CFAbsoluteTimeGetCurrent()
        try process.run()
        process.waitUntilExit()
        let wall = CFAbsoluteTimeGetCurrent() - t0

        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && process.terminationStatus != 2 {
            let msg = errText.isEmpty ? outText : errText
            throw NSError(
                domain: "MailExporter",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: msg.trimmingCharacters(in: .whitespacesAndNewlines),
                ]
            )
        }

        let lines = outText.split(whereSeparator: \.isNewline).map(String.init)
        let summaryLine = lines.first { !$0.hasPrefix("{") } ?? lines.first ?? ""
        var jsonLine = lines.last { $0.hasPrefix("{") } ?? "{}"

        // Annotate wall clock for local profiling without changing engine.
        if jsonLine.hasPrefix("{"),
           let data = jsonLine.data(using: .utf8),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            obj["clientWall_s"] = (wall * 1000).rounded() / 1000
            if let pretty = try? JSONSerialization.data(withJSONObject: obj),
               let s = String(data: pretty, encoding: .utf8)
            {
                jsonLine = s
            }
        }

        var matchCount: Int?
        if let data = jsonLine.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = obj["results"] as? [[String: Any]],
           let first = results.first
        {
            matchCount = first["matchCount"] as? Int
        }

        return EngineResult(
            line: summaryLine.isEmpty ? (errText.isEmpty ? "Done" : errText) : summaryLine,
            ok: process.terminationStatus == 0,
            rawJSON: jsonLine,
            matchCount: matchCount
        )
    }
}
