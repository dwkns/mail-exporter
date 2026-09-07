import Foundation
import AppKit
import UniformTypeIdentifiers

/// One Mail-style condition row.
struct MatchClause: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    /// Storage keys: entire|from|to|subject|body|date
    var field: String = "entire"
    var op: String = "contains"
    var value: String = ""
    var date: String = ""

    enum CodingKeys: String, CodingKey {
        case field, op, values, date, value
    }

    init(
        id: UUID = UUID(),
        field: String = "entire",
        op: String = "contains",
        value: String = "",
        date: String = ""
    ) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(String.self, forKey: .field)
        op = try c.decode(String.self, forKey: .op)
        if field.lowercased() == "date" {
            date = try c.decodeIfPresent(String.self, forKey: .date)
                ?? c.decodeIfPresent(String.self, forKey: .value)
                ?? ""
            value = ""
        } else if let values = try c.decodeIfPresent([String].self, forKey: .values),
                  !values.isEmpty
        {
            // Multiple values in one clause = OR; edit as comma-separated for now.
            value = values.joined(separator: ", ")
            date = ""
        } else {
            value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            date = ""
        }
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field)
        try c.encode(op, forKey: .op)
        if field.lowercased() == "date" {
            try c.encode(date, forKey: .date)
        } else {
            let parts = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            try c.encode(parts, forKey: .values)
        }
    }
}

/// One OR/AND group of conditions. Combine groups at the job level.
struct MatchGroup: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    /// any = OR within group; all = AND within group
    var conjunction: String = "any"
    var conditions: [MatchClause] = [MatchClause()]

    enum CodingKeys: String, CodingKey {
        case conjunction, conditions, mode
    }

    init(
        id: UUID = UUID(),
        conjunction: String = "any",
        conditions: [MatchClause] = [MatchClause()]
    ) {
        self.id = id
        self.conjunction = conjunction
        self.conditions = conditions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conjunction =
            try c.decodeIfPresent(String.self, forKey: .conjunction)
            ?? c.decodeIfPresent(String.self, forKey: .mode)
            ?? "any"
        conditions = try c.decodeIfPresent([MatchClause].self, forKey: .conditions)
            ?? [MatchClause()]
        if conditions.isEmpty {
            conditions = [MatchClause()]
        }
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conjunction, forKey: .conjunction)
        try c.encode(conditions, forKey: .conditions)
    }
}

struct ExportJob: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var outputDir: String
    /// How groups combine: typically "all" → (group1) AND (group2)
    var conjunction: String
    var groups: [MatchGroup]
    var includeSent: Bool
    var includeBin: Bool
    /// Base64-encoded URL bookmark data to track moved or renamed folders on disk
    var bookmark: String?

    enum CodingKeys: String, CodingKey {
        case id, name, outputDir, match, includeSent, includeBin, bookmark
    }

    init(
        id: String = UUID().uuidString,
        name: String = "New Mailbox",
        outputDir: String = NSHomeDirectory() + "/Desktop/Mail Export",
        conjunction: String = "all",
        groups: [MatchGroup] = [MatchGroup()],
        includeSent: Bool = true,
        includeBin: Bool = false,
        bookmark: String? = nil
    ) {
        self.id = id
        self.name = name
        self.outputDir = outputDir
        self.conjunction = conjunction
        self.groups = groups
        self.includeSent = includeSent
        self.includeBin = includeBin
        self.bookmark = bookmark
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        outputDir = try c.decode(String.self, forKey: .outputDir)
        includeSent = try c.decodeIfPresent(Bool.self, forKey: .includeSent) ?? true
        includeBin = try c.decodeIfPresent(Bool.self, forKey: .includeBin) ?? false
        bookmark = try c.decodeIfPresent(String.self, forKey: .bookmark)
        // Ignore legacy lastRunSummary / lastRunDetail — export feedback is session-only.

        if let match = try c.decodeIfPresent(MatchPayload.self, forKey: .match) {
            conjunction = match.conjunction
            groups = match.groups
        } else {
            conjunction = "all"
            groups = [MatchGroup()]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(outputDir, forKey: .outputDir)
        try c.encode(includeSent, forKey: .includeSent)
        try c.encode(includeBin, forKey: .includeBin)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(
            MatchPayload(conjunction: conjunction, groups: groups),
            forKey: .match
        )
    }
}

private struct MatchPayload: Codable {
    var conjunction: String
    var groups: [MatchGroup]

    enum CodingKeys: String, CodingKey {
        case conjunction, groups, conditions, mode, any, all
    }

    init(conjunction: String, groups: [MatchGroup]) {
        self.conjunction = conjunction
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let groups = try c.decodeIfPresent([MatchGroup].self, forKey: .groups),
           !groups.isEmpty
        {
            self.groups = groups
            self.conjunction =
                try c.decodeIfPresent(String.self, forKey: .conjunction)
                ?? c.decodeIfPresent(String.self, forKey: .mode)
                ?? "all"
            return
        }

        // Flat legacy → one group
        let flatConjunction: String
        let conditions: [MatchClause]
        if let conds = try c.decodeIfPresent([MatchClause].self, forKey: .conditions) {
            conditions = conds
            flatConjunction =
                try c.decodeIfPresent(String.self, forKey: .conjunction)
                ?? c.decodeIfPresent(String.self, forKey: .mode)
                ?? "all"
        } else if let any = try c.decodeIfPresent([MatchClause].self, forKey: .any) {
            conditions = any
            flatConjunction = "any"
        } else if let all = try c.decodeIfPresent([MatchClause].self, forKey: .all) {
            conditions = all
            flatConjunction = "all"
        } else {
            conditions = [MatchClause()]
            flatConjunction = "any"
        }

        self.conjunction = "all"
        self.groups = [
            MatchGroup(
                conjunction: flatConjunction,
                conditions: conditions.isEmpty ? [MatchClause()] : conditions
            ),
        ]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conjunction, forKey: .conjunction)
        try c.encode(groups, forKey: .groups)
    }
}

struct JobsDocument: Codable {
    var jobs: [ExportJob]
}

enum FolderStatus: Equatable {
    case exists(URL)
    case moved(suggestedURL: URL)
    case inTrash(trashURL: URL)
    case notFound(candidateURL: URL?)

    var isValidForExport: Bool {
        if case .exists = self { return true }
        return false
    }

    var existingURL: URL? {
        if case .exists(let url) = self { return url }
        return nil
    }
}

@MainActor
final class JobsStore: ObservableObject {
    @Published var jobs: [ExportJob] = []
    @Published var selectedID: String?
    @Published var status: String = ""
    /// Shown only in Mailboxes when Mail library access is blocked.
    @Published var needsFullDiskAccess: Bool = false
    @Published var needsAccessibility: Bool = false

    static var icloudDocsURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return nil
    }

    static var defaultICloudURL: URL? {
        guard let docs = icloudDocsURL else { return nil }
        return docs.appendingPathComponent("MailExporter/jobs.json")
    }

    static var defaultLocalURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MailExporter/jobs.json")
    }

    static func defaultConfigURL() -> URL {
        let prefs = AppPreferences.shared
        switch prefs.storageLocation {
        case .iCloud:
            if let icloud = defaultICloudURL {
                return icloud
            }
            return defaultLocalURL
        case .local:
            return defaultLocalURL
        case .custom:
            let trimmed = prefs.customStoragePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let path = (trimmed as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: path)
                if url.pathExtension.lowercased() == "json" {
                    return url
                }
                return url.appendingPathComponent("jobs.json")
            }
            return defaultLocalURL
        }
    }

    var configURL: URL {
        Self.defaultConfigURL()
    }

    var projectRoot: URL {
        if let env = ProcessInfo.processInfo.environment["MAILEXPORTER_ROOT"] {
            return URL(fileURLWithPath: env)
        }
        let bundle = Bundle.main.bundleURL
        let mailExporterDir = bundle.deletingLastPathComponent()
        let appsDir = mailExporterDir.deletingLastPathComponent()
        let root = appsDir.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("engine").path) {
            return root
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("engine").path) {
            return cwd
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Developer/mail-exporter")
    }

    init() {
        Self.autoMigrateToICloudIfNeeded()
        reload()
        refreshMailAccess()
    }

    static func autoMigrateToICloudIfNeeded() {
        guard AppPreferences.shared.storageLocation == .iCloud,
              let icloudURL = defaultICloudURL else { return }
        let localURL = defaultLocalURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: icloudURL.path) && fm.fileExists(atPath: localURL.path) {
            do {
                try fm.createDirectory(
                    at: icloudURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: localURL, to: icloudURL)
            } catch {
                // If migration fails, reload() will fall back to localURL
            }
        }
    }

    func refreshMailAccess() {
        needsFullDiskAccess = !MailAccessProbe.canAccessMailLibrary()
        needsAccessibility = !MailAccessProbe.canAccessAccessibility()
    }

    func switchLocation(to newLocation: StorageLocation, customPath: String? = nil) {
        let previousJobs = jobs
        AppPreferences.shared.storageLocation = newLocation
        if let customPath = customPath {
            AppPreferences.shared.customStoragePath = customPath
        }
        let targetURL = configURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        if !fm.fileExists(atPath: targetURL.path) && !previousJobs.isEmpty {
            save()
        } else {
            reload()
        }
    }

    func reload() {
        let url = configURL
        let fm = FileManager.default
        var targetURL = url
        if !fm.fileExists(atPath: targetURL.path) && targetURL != Self.defaultLocalURL && fm.fileExists(atPath: Self.defaultLocalURL.path) {
            targetURL = Self.defaultLocalURL
        }

        guard fm.fileExists(atPath: targetURL.path) else {
            jobs = []
            status = "No mailboxes yet"
            return
        }
        do {
            let data = try Data(contentsOf: targetURL)
            let doc = try JSONDecoder().decode(JobsDocument.self, from: data)
            jobs = doc.jobs
            if selectedID == nil {
                selectedID = jobs.first?.id
            }
            let n = jobs.count
            status = n == 1 ? "1 mailbox" : "\(n) mailboxes"
            if targetURL != url {
                save()
            } else {
                detectMovedTargetFolders()
            }
        } catch {
            status = "Couldn’t open mailboxes: \(error.localizedDescription)"
        }
    }

    func promptExportSettings() {
        let savePanel = NSSavePanel()
        savePanel.title = "Export MailExporter Settings"
        savePanel.prompt = "Export"
        savePanel.nameFieldStringValue = "MailExporter-Settings.json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                let targetURL = configURL.resolvingSymlinksInPath()
                let fm = FileManager.default
                if fm.fileExists(atPath: targetURL.path) {
                    try? fm.removeItem(at: url)
                    try fm.copyItem(at: targetURL, to: url)
                } else {
                    let data = try JSONEncoder().encode(JobsDocument(jobs: jobs))
                    let obj = try JSONSerialization.jsonObject(with: data)
                    let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                    try pretty.write(to: url, options: .atomic)
                }
                status = "Exported settings to \(url.lastPathComponent)"
            } catch {
                status = "Export settings failed: \(error.localizedDescription)"
            }
        }
    }

    func promptImportSettings() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Import MailExporter Settings"
        openPanel.prompt = "Import"
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        if openPanel.runModal() == .OK, let url = openPanel.url {
            do {
                let data = try Data(contentsOf: url)
                let doc = try JSONDecoder().decode(JobsDocument.self, from: data)
                jobs = doc.jobs
                if selectedID == nil {
                    selectedID = jobs.first?.id
                }
                save()
                status = "Imported \(jobs.count) mailbox\(jobs.count == 1 ? "" : "es") from \(url.lastPathComponent)"
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t Import Settings"
                alert.informativeText = "The file is not a valid MailExporter settings file:\n\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func resetToFactorySettings() {
        let fm = FileManager.default
        for job in jobs {
            cleanUpScaffoldFolderIfEmpty(at: job.outputDir)
        }
        let localPath = Self.defaultLocalURL.path
        if fm.fileExists(atPath: localPath) {
            try? fm.removeItem(atPath: localPath)
        }
        if let icloudPath = Self.defaultICloudURL?.path, fm.fileExists(atPath: icloudPath) {
            try? fm.removeItem(atPath: icloudPath)
        }
        if !AppPreferences.shared.customStoragePath.isEmpty {
            let custom = (AppPreferences.shared.customStoragePath as NSString).expandingTildeInPath
            if fm.fileExists(atPath: custom) {
                try? fm.removeItem(atPath: custom)
            }
        }
        AppPreferences.shared.reset()
        jobs = []
        selectedID = nil
        saveWithoutMoveDetection()
        status = "Reset to factory defaults"
    }

    private func isScaffoldOnlyFolder(at path: String) -> Bool {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return false }
        var regularFiles: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if let res = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), res.isRegularFile == true {
                regularFiles.append(fileURL)
            }
        }
        if regularFiles.isEmpty { return true }
        if regularFiles.count == 1 && regularFiles.first?.lastPathComponent == "_how_to_use.md" { return true }
        return false
    }

    private func cleanUpScaffoldFolderIfEmpty(at path: String) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        guard isScaffoldOnlyFolder(at: url.path) else { return }

        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        var targetToDelete = url
        var current = url
        while current.pathComponents.count > home.pathComponents.count + 2 {
            let parent = current.deletingLastPathComponent()
            if parent.pathComponents.count <= home.pathComponents.count + 1 { break }
            if isScaffoldOnlyFolder(at: parent.path) {
                targetToDelete = parent
                current = parent
            } else {
                break
            }
        }
        try? fm.trashItem(at: targetToDelete, resultingItemURL: nil)
    }

    func save() {
        do {
            let targetURL = configURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(JobsDocument(jobs: jobs))
            let obj = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
            )
            try pretty.write(to: targetURL, options: .atomic)
            status = "Saved"
        } catch {
            status = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    /// Prepares subdirectories (Drafts, Sent) and writes _how_to_use.md inside confirmed export folder before export.
    func prepareOutputDirectory(for job: ExportJob) throws {
        let raw = job.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let path = (raw as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw NSError(
                    domain: "MailExporter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Export path is a file, not a folder: \(path)"]
                )
            }
        } else {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        for sub in ["Drafts", "Sent"] {
            try fm.createDirectory(
                atPath: (path as NSString).appendingPathComponent(sub),
                withIntermediateDirectories: true
            )
        }
        writeHowToUse(in: path, mailboxName: job.name)
    }

    /// Refresh the bookmark for a job from its current outputDir on disk if the directory exists.
    func refreshBookmark(for index: Int) {
        guard jobs.indices.contains(index) else { return }
        let raw = jobs[index].outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let path = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                jobs[index].bookmark = data.base64EncodedString()
            }
        }
    }

    func updateOutputDir(for jobID: String, newPath: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[idx].outputDir = newPath
        refreshBookmark(for: idx)
        save()
    }

    func promptChooseFolder(for jobID: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder for “\(jobs[idx].name)”"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            jobs[idx].outputDir = url.path
            refreshBookmark(for: idx)
            save()
        }
    }

    func folderStatus(for job: ExportJob) -> FolderStatus {
        let raw = job.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .notFound(candidateURL: nil) }
        let path = ((raw as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false

        // 1. Existing folder on disk
        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return .exists(URL(fileURLWithPath: path))
        }

        // 2. Check bookmark resolution for moved folder or trash
        if let b64 = job.bookmark, let data = Data(base64Encoded: b64) {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                let resolvedPath = resolvedURL.resolvingSymlinksInPath().path
                var resIsDir: ObjCBool = false
                if fm.fileExists(atPath: resolvedPath, isDirectory: &resIsDir), resIsDir.boolValue {
                    if resolvedPath.contains("/.Trash/") || resolvedPath.contains("/Trash/") {
                        return .inTrash(trashURL: resolvedURL)
                    } else if resolvedPath != path {
                        return .moved(suggestedURL: resolvedURL)
                    }
                }
            }
        }

        // 3. Search common locations for candidate
        let candidate = findCandidateFolder(for: job)
        return .notFound(candidateURL: candidate)
    }

    func findCandidateFolder(for job: ExportJob) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let searchBases = [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads")
        ]
        let pathURL = URL(fileURLWithPath: (job.outputDir as NSString).expandingTildeInPath)
        let namesToSearch = [
            job.name,
            pathURL.lastPathComponent,
            pathURL.deletingLastPathComponent().lastPathComponent
        ].filter { !$0.isEmpty && $0 != "/" && $0 != "Email" }

        for base in searchBases {
            for name in namesToSearch {
                let candidate = base.appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    let subTarget = candidate.appendingPathComponent("Email/From Mac Mail")
                    if fm.fileExists(atPath: subTarget.path, isDirectory: &isDir), isDir.boolValue {
                        return subTarget
                    }
                    return candidate
                }
            }
        }
        return nil
    }

    /// Detect if any export target folders have been moved or renamed on disk.
    /// Updates the job's outputDir and bookmark and saves jobs.json if any moves are detected.
    @discardableResult
    func detectMovedTargetFolders(jobID: String? = nil) -> [(job: ExportJob, oldPath: String, newPath: String)] {
        var moved: [(job: ExportJob, oldPath: String, newPath: String)] = []
        let fm = FileManager.default
        var dirty = false

        for i in jobs.indices {
            if let jobID = jobID, jobs[i].id != jobID {
                continue
            }
            let job = jobs[i]
            guard let b64 = job.bookmark, let data = Data(base64Encoded: b64) else {
                refreshBookmark(for: i)
                if jobs[i].bookmark != nil { dirty = true }
                continue
            }

            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                let resolvedPath = resolvedURL.resolvingSymlinksInPath().path
                let currentPath = ((job.outputDir as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath

                var isDir: ObjCBool = false
                if resolvedPath != currentPath && fm.fileExists(atPath: resolvedPath, isDirectory: &isDir) && isDir.boolValue {
                    // Do not auto-update to Trash
                    if !resolvedPath.contains("/.Trash/") && !resolvedPath.contains("/Trash/") {
                        let old = job.outputDir
                        jobs[i].outputDir = resolvedPath
                        if let fresh = try? resolvedURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                            jobs[i].bookmark = fresh.base64EncodedString()
                        }
                        moved.append((job: jobs[i], oldPath: old, newPath: resolvedPath))
                        dirty = true
                    }
                } else if isStale {
                    if let fresh = try? resolvedURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        jobs[i].bookmark = fresh.base64EncodedString()
                        dirty = true
                    }
                }
            } else {
                refreshBookmark(for: i)
                if jobs[i].bookmark != b64 { dirty = true }
            }
        }

        if dirty {
            saveWithoutMoveDetection()
        }
        return moved
    }

    private func saveWithoutMoveDetection() {
        save()
    }

    private func writeHowToUse(in folderPath: String, mailboxName: String) {
        let dest = URL(fileURLWithPath: folderPath)
            .appendingPathComponent("_how_to_use.md")
        var template: String
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/_how_to_use.md")
        if let text = try? String(contentsOf: bundled, encoding: .utf8) {
            template = text
        } else if let url = Bundle.main.url(forResource: "_how_to_use", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
        {
            template = text
        } else {
            template = Self.fallbackHowToTemplate
        }
        let body = template
            .replacingOccurrences(of: "{{MAILBOX_NAME}}", with: mailboxName)
            .replacingOccurrences(of: "{{OUTPUT_DIR}}", with: folderPath)
        try? body.write(to: dest, atomically: true, encoding: .utf8)
    }

    private static let fallbackHowToTemplate = """
    # MailExporter — how to use this folder

    Smart mailbox: **{{MAILBOX_NAME}}**
    Path: `{{OUTPUT_DIR}}`

    This folder holds exported Apple Mail messages (`*.eml`) for AI admin context.
    Write Markdown drafts in `{{OUTPUT_DIR}}/Drafts` as `NNN_who_subject.md`.
    After an exported `.eml` shows the mail was sent, move that file to `{{OUTPUT_DIR}}/Sent`.

    Use the MailExporter MCP (`python3 -m mailexporter_mcp` from the mail-exporter repo):
    `list_jobs`, `list_messages`, `read_message`, `compose_draft`, `check_matches`, `export_job`.
    """

    func addJob() {
        let job = ExportJob()
        jobs.append(job)
        selectedID = job.id
        save()
    }

    func deleteJob(id: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        let name = jobs[idx].name
        jobs.remove(at: idx)
        if selectedID == id {
            selectedID = jobs.first?.id
        }
        save()
        status = "Removed “\(name)”"
    }

    func deleteSelected() {
        guard let selectedID else { return }
        deleteJob(id: selectedID)
    }
}
