import Foundation

enum ProjectLayout {
    static let emailDir = "Email"
    static let documentsDir = "Documents"
    static let notesDir = "Notes"
    static let archiveDir = "_archive"
    static let statusFile = "STATUS.md"
    static let howToFile = "how_to_use.md"
    static let legacyHowToFile = "_how_to_use.md"

    static var defaultParent: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/home")
    }

    static func sanitizedFolderName(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "/", with: "-")
        text = text.replacingOccurrences(of: ":", with: "-")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return text.isEmpty ? "Untitled" : text
    }

    static func inferProjectRoot(from path: String) -> String {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            url.deleteLastPathComponent()
        }
        if url.lastPathComponent == "Drafts" {
            url.deleteLastPathComponent()
        }
        if url.lastPathComponent == emailDir {
            url.deleteLastPathComponent()
        }
        return url.path
    }

    @discardableResult
    static func ensure(at projectRoot: URL, mailboxName: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let email = projectRoot.appendingPathComponent(emailDir)
        try fm.createDirectory(at: email, withIntermediateDirectories: true)
        try fm.createDirectory(at: email.appendingPathComponent("Drafts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: email.appendingPathComponent("Sent"), withIntermediateDirectories: true)
        try fm.createDirectory(at: projectRoot.appendingPathComponent(documentsDir), withIntermediateDirectories: true)
        try fm.createDirectory(at: projectRoot.appendingPathComponent(notesDir), withIntermediateDirectories: true)
        try fm.createDirectory(at: projectRoot.appendingPathComponent(archiveDir), withIntermediateDirectories: true)
        let status = projectRoot.appendingPathComponent(statusFile)
        if !fm.fileExists(atPath: status.path) {
            let title = mailboxName.trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = title.isEmpty ? projectRoot.lastPathComponent : title
            let body = """
            # \(heading)

            Status: open

            ## Where we are

            (one paragraph)

            ## Last sent

            ## Next action
            """
            try body.write(to: status, atomically: true, encoding: .utf8)
        }
        return email
    }

    static func createProject(name: String, parent: String) throws -> (project: URL, email: URL) {
        let parentURL = URL(fileURLWithPath: (parent as NSString).expandingTildeInPath)
        let root = parentURL.appendingPathComponent(sanitizedFolderName(name))
        let email = try ensure(at: root, mailboxName: name)
        return (root, email)
    }
}
