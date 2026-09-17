import Foundation

enum MCPInstall {
    static let helperPath =
        "/Applications/MailExporter.app/Contents/Resources/MailExporterEngine/MailExporterEngine"

    static func installCursor() -> String {
        writeMCPConfig(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor/mcp.json")
        )
    }

    static func installClaude() -> String {
        writeMCPConfig(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Claude/claude_desktop_config.json"
                )
        )
    }

    static func installSkill() -> String {
        guard let source = bundledSkill() else {
            return "Skill file is missing from the app bundle."
        }
        let homes = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor/skills/mail-exporter/SKILL.md"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/skills/mail-exporter/SKILL.md"),
        ]
        var wrote: [String] = []
        for dest in homes {
            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: source, to: dest)
                wrote.append(dest.path)
            } catch {
                return "Couldn’t install skill: \(error.localizedDescription)"
            }
        }
        return "Wrote \(wrote.joined(separator: " and "))."
    }

    private static func bundledSkill() -> URL? {
        let inApp = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/skills/mail-exporter/SKILL.md")
        if FileManager.default.isReadableFile(atPath: inApp.path) {
            return inApp
        }
        return nil
    }

    private static func writeMCPConfig(_ url: URL) -> String {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return "Install MailExporter to /Applications first."
        }
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["mail-exporter"] = [
            "command": helperPath,
            "args": ["mcp"],
        ]
        root["mcpServers"] = servers
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            return "Wrote \(url.path). Restart the app to load it."
        } catch {
            return "Couldn’t write MCP config: \(error.localizedDescription)"
        }
    }
}
