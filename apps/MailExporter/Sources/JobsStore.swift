import Foundation
import AppKit
import Darwin
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
    /// Case-file root (parent of Email/). Empty means infer from outputDir.
    var projectDir: String?
    /// How groups combine: typically "all" → (group1) AND (group2)
    var conjunction: String
    var groups: [MatchGroup]
    var includeSent: Bool
    var includeBin: Bool
    var includeThread: Bool
    /// Optional scan root for synthetic / test mailboxes. Empty means ~/Library/Mail.
    var mailRoot: String?
    /// Base64-encoded URL bookmark data to track moved or renamed folders on disk
    var bookmark: String?

    enum CodingKeys: String, CodingKey {
        case id, name, outputDir, projectDir, match, includeSent, includeBin, includeThread, mailRoot, bookmark
    }

    init(
        id: String = UUID().uuidString,
        name: String = "New Project",
        outputDir: String = "",
        projectDir: String? = nil,
        conjunction: String = "all",
        groups: [MatchGroup] = [MatchGroup()],
        includeSent: Bool = true,
        includeBin: Bool = false,
        includeThread: Bool = false,
        mailRoot: String? = nil,
        bookmark: String? = nil
    ) {
        self.id = id
        self.name = name
        self.outputDir = outputDir
        self.projectDir = projectDir
        self.conjunction = conjunction
        self.groups = groups
        self.includeSent = includeSent
        self.includeBin = includeBin
        self.includeThread = includeThread
        self.mailRoot = mailRoot
        self.bookmark = bookmark
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        outputDir = try c.decode(String.self, forKey: .outputDir)
        projectDir = try c.decodeIfPresent(String.self, forKey: .projectDir)
        includeSent = try c.decodeIfPresent(Bool.self, forKey: .includeSent) ?? true
        includeBin = try c.decodeIfPresent(Bool.self, forKey: .includeBin) ?? false
        includeThread = try c.decodeIfPresent(Bool.self, forKey: .includeThread) ?? false
        mailRoot = try c.decodeIfPresent(String.self, forKey: .mailRoot)
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
        if let projectDir, !projectDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try c.encode(projectDir, forKey: .projectDir)
        }
        try c.encode(includeSent, forKey: .includeSent)
        try c.encode(includeBin, forKey: .includeBin)
        try c.encode(includeThread, forKey: .includeThread)
        if let mailRoot, !mailRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try c.encode(mailRoot, forKey: .mailRoot)
        }
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
    case unset
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

/// Reloads `jobs.json` when iCloud (or another Mac) writes it.
private final class JobsCloudPresenter: NSObject, NSFilePresenter {
    var presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    var onChange: (() -> Void)?

    override init() {
        let queue = OperationQueue()
        queue.name = "com.dwkns.MailExporter.jobs-presenter"
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidChange() {
        onChange?()
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
        onChange?()
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        onChange?()
        completionHandler(nil)
    }
}

/// Owns the iCloud presenter + directory watch so JobsStore deinit stays isolation-safe.
private final class JobsCloudWatch {
    private var presenter: JobsCloudPresenter?
    private var watch: DispatchSourceFileSystemObject?

    func stop() {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenter = nil
        watch?.cancel()
        watch = nil
    }

    func start(url: URL, onChange: @escaping () -> Void) {
        stop()
        let presenter = JobsCloudPresenter()
        presenter.presentedItemURL = url
        presenter.onChange = onChange
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter

        let folder = url.deletingLastPathComponent()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler {
            onChange()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        watch = source
    }

    deinit {
        stop()
    }
}

@MainActor
final class JobsStore: ObservableObject {
    @Published var jobs: [ExportJob] = []
    @Published var status: String = ""
    /// Shown when Mail library access is blocked.
    @Published var needsFullDiskAccess: Bool = false
    @Published var needsAccessibility: Bool = false
    @Published var needsAutomation: Bool = false

    private let cloudWatch = JobsCloudWatch()
    private var ignoreCloudReloadUntil = Date.distantPast
    private var ubiquityObserver: NSObjectProtocol?

    /// Private iCloud ubiquity container (does not appear as an iCloud Drive folder).
    static let iCloudContainerIdentifier = "iCloud.com.dwkns.MailExporter"

    /// Root of the app's ubiquity container, or nil when iCloud is signed out / unavailable.
    static var iCloudContainerURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: iCloudContainerIdentifier)
    }

    /// Whether the ubiquity container is currently available.
    static var isICloudAvailable: Bool {
        iCloudContainerURL != nil
    }

    /// Preferred jobs.json location inside the private ubiquity container.
    static var defaultICloudURL: URL? {
        guard let container = iCloudContainerURL else { return nil }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("jobs.json")
    }

    /// Legacy path from the old "visible iCloud Drive folder" storage.
    static var legacyCloudDocsJobsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/MailExporter/jobs.json"
            )
    }

    static var defaultLocalURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MailExporter/jobs.json")
    }

    /// Plain-text path so CLI/MCP open the same jobs.json as this app.
    static var jobsLocationPointerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MailExporter/jobs-location")
    }

    static func writeJobsLocationPointer(_ url: URL) {
        let pointer = jobsLocationPointerURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: pointer.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try url.path.write(to: pointer, atomically: true, encoding: .utf8)
        } catch {
            // Engine still has filesystem fallbacks if the pointer cannot be written.
        }
    }

    static func defaultConfigURL() -> URL {
        let prefs = AppPreferences.shared
        switch prefs.storageLocation {
        case .iCloud:
            if let icloud = defaultICloudURL {
                return icloud
            }
            // iCloud signed out / unavailable — keep writing locally until it returns.
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
        Self.ensureICloudJobsDownloaded()
        Self.writeJobsLocationPointer(Self.defaultConfigURL())
        reload()
        refreshMailAccess()
        startWatchingJobsFile()
        observeUbiquityIdentity()
    }

    /// Ask iCloud to materialize `jobs.json` (and its Documents folder) if the
    /// item exists in the cloud but is not yet local.
    static func ensureICloudJobsDownloaded() {
        guard let url = defaultICloudURL else { return }
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.startDownloadingUbiquitousItem(at: folder)
        if fm.fileExists(atPath: url.path) || fm.isUbiquitousItem(at: url) {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    private func observeUbiquityIdentity() {
        ubiquityObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleUbiquityIdentityChange()
            }
        }
    }

    private func handleUbiquityIdentityChange() {
        Self.autoMigrateToICloudIfNeeded()
        Self.ensureICloudJobsDownloaded()
        Self.writeJobsLocationPointer(Self.defaultConfigURL())
        reload()
        startWatchingJobsFile()
    }

    private func startWatchingJobsFile() {
        let url = configURL
        cloudWatch.start(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadIfExternalChange()
            }
        }
    }

    private func reloadIfExternalChange() {
        if Date() < ignoreCloudReloadUntil { return }
        reload()
    }

    static func coordinateRead(from url: URL) throws -> Data {
        let fm = FileManager.default
        if fm.isUbiquitousItem(at: url) {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        var coordError: NSError?
        var result: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordError
        ) { readable in
            do {
                result = try Data(contentsOf: readable)
            } catch {
                readError = error
            }
        }
        if let coordError { throw coordError }
        if let readError { throw readError }
        guard let result else {
            throw NSError(
                domain: "MailExporter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Couldn’t read jobs.json"]
            )
        }
        return result
    }

    static func coordinateWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordError
        ) { writable in
            do {
                try data.write(to: writable, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// Migrates jobs.json into the private ubiquity container once, preferring the
    /// legacy CloudDocs copy when present, then local Application Support.
    static func autoMigrateToICloudIfNeeded() {
        guard AppPreferences.shared.storageLocation == .iCloud,
              let icloudURL = defaultICloudURL else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: icloudURL.path) { return }

        let candidates: [URL] = [legacyCloudDocsJobsURL, defaultLocalURL]
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return
        }
        do {
            try fm.createDirectory(
                at: icloudURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: source, to: icloudURL)
            // Stop using the visible Drive folder; leave the file in place so the
            // user can delete it manually if they want.
        } catch {
            // If migration fails, reload() can still read the legacy/local copy.
        }
    }

    func refreshMailAccess() {
        needsFullDiskAccess = !MailAccessProbe.canAccessMailLibrary()
        needsAccessibility = !MailAccessProbe.canAccessAccessibility()
        needsAutomation = UserDefaults.standard.bool(forKey: "mailExporterNeedsAutomation")
    }

    func flagAutomationRequired() {
        UserDefaults.standard.set(true, forKey: "mailExporterNeedsAutomation")
        UserDefaults.standard.set(false, forKey: "dismissedAutomationWarning")
        needsAutomation = true
    }

    func clearAutomationRequired() {
        UserDefaults.standard.set(false, forKey: "mailExporterNeedsAutomation")
        needsAutomation = false
    }

    /// Re-show the Full Disk banner after a real access failure (overrides prior dismiss).
    func flagFullDiskAccessRequired() {
        UserDefaults.standard.set(false, forKey: "dismissedFullDiskWarning")
        needsFullDiskAccess = true
    }

    func switchLocation(to newLocation: StorageLocation, customPath: String? = nil) {
        let previousJobs = jobs
        AppPreferences.shared.storageLocation = newLocation
        if let customPath = customPath {
            AppPreferences.shared.customStoragePath = customPath
        }
        let targetURL = configURL.resolvingSymlinksInPath()
        Self.writeJobsLocationPointer(targetURL)
        let fm = FileManager.default
        if !fm.fileExists(atPath: targetURL.path) && !previousJobs.isEmpty {
            save()
        } else {
            reload()
        }
        startWatchingJobsFile()
    }

    func reload() {
        let url = configURL
        let fm = FileManager.default
        var targetURL = url
        if !fm.fileExists(atPath: targetURL.path) {
            let fallbacks = [Self.legacyCloudDocsJobsURL, Self.defaultLocalURL]
            if let fallback = fallbacks.first(where: {
                $0 != targetURL && fm.fileExists(atPath: $0.path)
            }) {
                targetURL = fallback
            }
        }

        guard fm.fileExists(atPath: targetURL.path) else {
            jobs = []
            status = "No exports yet"
            return
        }
        do {
            let data = try Self.coordinateRead(from: targetURL)
            let doc = try JSONDecoder().decode(JobsDocument.self, from: data)
            jobs = doc.jobs
            let n = jobs.count
            status = n == 1 ? "1 export" : "\(n) exports"
            if targetURL != url {
                save()
            }
            syncHowToUseToAllJobs()
        } catch {
            status = "Couldn’t open exports: \(error.localizedDescription)"
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
                save()
                syncHowToUseToAllJobs()
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
        let pathsToRemove: [String] = [
            Self.defaultLocalURL.path,
            Self.defaultICloudURL?.path,
            Self.legacyCloudDocsJobsURL.path,
        ].compactMap { $0 }
        for path in pathsToRemove {
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
        if !AppPreferences.shared.customStoragePath.isEmpty {
            let custom = (AppPreferences.shared.customStoragePath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: custom)
            let file = url.pathExtension.lowercased() == "json"
                ? url : url.appendingPathComponent("jobs.json")
            if fm.fileExists(atPath: file.path) {
                try? fm.removeItem(at: file)
            }
        }
        AppPreferences.shared.reset()
        jobs = []
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
        let names = Set(regularFiles.map(\.lastPathComponent))
        if names.isSubset(of: [ProjectLayout.howToFile, ProjectLayout.legacyHowToFile, ProjectLayout.statusFile]) {
            return true
        }
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
            ignoreCloudReloadUntil = Date().addingTimeInterval(1.5)
            try Self.coordinateWrite(pretty, to: targetURL)
            Self.writeJobsLocationPointer(targetURL)
            status = "Saved"
            startWatchingJobsFile()
        } catch {
            status = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    /// Prepares the case-file layout and writes how_to_use.md before export.
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
        let projectPath = (job.projectDir?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProjectLayout.inferProjectRoot(from: path)
        let projectURL = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
        try ProjectLayout.ensure(at: projectURL, mailboxName: job.name)
        writeHowToUse(in: path, mailboxName: job.name, projectDir: projectURL.path)
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
        writeHowToUseIfFolderExists(jobs[idx])
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
            writeHowToUseIfFolderExists(jobs[idx])
        }
    }

    static func isForbiddenOutputDir(_ raw: String) -> Bool {
        let path = ((raw as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
        if path == "/" { return true }
        let mail = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mail")
        if path == mail || path.hasPrefix(mail + "/") { return true }
        return false
    }

    func folderStatus(for job: ExportJob) -> FolderStatus {
        let raw = job.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .unset }
        if Self.isForbiddenOutputDir(raw) {
            return .notFound(candidateURL: nil)
        }
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
                    let email = candidate.appendingPathComponent(ProjectLayout.emailDir)
                    if fm.fileExists(atPath: email.path, isDirectory: &isDir), isDir.boolValue {
                        return email
                    }
                    let legacy = candidate.appendingPathComponent("From Mac Mail")
                    if fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue {
                        return legacy
                    }
                    return candidate
                }
            }
        }
        return nil
    }

    /// Bookmarks can show a moved folder. Never rewrite `outputDir` — the row
    /// offers **Use Found**. Silent rewrites break iCloud (paths/bookmarks are per-Mac).
    @discardableResult
    func detectMovedTargetFolders(jobID: String? = nil) -> [(job: ExportJob, oldPath: String, newPath: String)] {
        var moved: [(job: ExportJob, oldPath: String, newPath: String)] = []

        for i in jobs.indices {
            if let jobID = jobID, jobs[i].id != jobID {
                continue
            }
            let job = jobs[i]
            if case .moved(let suggestedURL) = folderStatus(for: job) {
                moved.append((job: job, oldPath: job.outputDir, newPath: suggestedURL.path))
            }
        }
        return moved
    }

    private func saveWithoutMoveDetection() {
        save()
    }

    /// Rewrite `how_to_use.md` in every project that exists on this Mac.
    /// Skips missing / moved / Trash folders. Identical files are left untouched.
    func syncHowToUseToAllJobs() {
        for job in jobs {
            writeHowToUseIfFolderExists(job)
        }
    }

    private func writeHowToUseIfFolderExists(_ job: ExportJob) {
        guard case .exists(let url) = folderStatus(for: job) else { return }
        let project = (job.projectDir?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProjectLayout.inferProjectRoot(from: url.path)
        writeHowToUse(in: url.path, mailboxName: job.name, projectDir: project)
    }

    private func writeHowToUse(in folderPath: String, mailboxName: String, projectDir: String? = nil) {
        let emailURL = URL(fileURLWithPath: folderPath)
        let projectPath = projectDir ?? ProjectLayout.inferProjectRoot(from: folderPath)
        let dest = URL(fileURLWithPath: projectPath).appendingPathComponent(ProjectLayout.howToFile)
        var template: String
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/\(ProjectLayout.howToFile)")
        if let text = try? String(contentsOf: bundled, encoding: .utf8) {
            template = text
        } else if let url = Bundle.main.url(forResource: "how_to_use", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
        {
            template = text
        } else {
            template = Self.fallbackHowToTemplate
        }
        let body = template
            .replacingOccurrences(of: "{{MAILBOX_NAME}}", with: mailboxName)
            .replacingOccurrences(of: "{{OUTPUT_DIR}}", with: folderPath)
            .replacingOccurrences(of: "{{PROJECT_DIR}}", with: projectPath)
        if let existing = try? String(contentsOf: dest, encoding: .utf8), existing == body {
            removeLegacyHowTo(in: emailURL)
            removeLegacyHowTo(in: URL(fileURLWithPath: projectPath))
            return
        }
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? body.write(to: dest, atomically: true, encoding: .utf8)
        removeLegacyHowTo(in: emailURL)
        removeLegacyHowTo(in: URL(fileURLWithPath: projectPath))
    }

    private func removeLegacyHowTo(in folder: URL) {
        let stale = folder.appendingPathComponent(ProjectLayout.legacyHowToFile)
        try? FileManager.default.removeItem(at: stale)
    }

    private static let fallbackHowToTemplate = """
    # {{MAILBOX_NAME}}

    Read `how_to_use.md` and `STATUS.md`, then the `.eml` files in `{{OUTPUT_DIR}}`.
    Ask the owner for more background, or what to do next. Never send mail.
    """

    func createProject(named name: String, parent: String) throws -> ExportJob {
        if isForbiddenOutputDir(parent) {
            throw NSError(
                domain: "MailExporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "That folder can’t be used as a project parent."]
            )
        }
        let created = try ProjectLayout.createProject(name: name, parent: parent)
        UserDefaults.standard.set(parent, forKey: "lastProjectParent")
        var job = ExportJob(name: name)
        applyFolderToJob(&job, url: created.email)
        job.projectDir = created.project.path
        job.outputDir = created.email.path
        writeHowToUse(
            in: created.email.path,
            mailboxName: name,
            projectDir: created.project.path
        )
        return job
    }

    /// Insert or replace a job and write `jobs.json`. Refreshes `how_to_use.md` if the folder exists.
    func upsertJob(_ job: ExportJob) {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
            refreshBookmark(for: idx)
        } else {
            jobs.append(job)
            if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                refreshBookmark(for: idx)
            }
        }
        save()
        writeHowToUseIfFolderExists(job)
    }

    /// Encode `jobs` plus an optional draft overlay to a temp file (Check Matches
    /// without committing the sheet).
    func temporaryConfigURL(including draft: ExportJob) throws -> URL {
        var tempJobs = jobs
        if let idx = tempJobs.firstIndex(where: { $0.id == draft.id }) {
            tempJobs[idx] = draft
        } else {
            tempJobs.append(draft)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailexporter-preview-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(JobsDocument(jobs: tempJobs))
        let obj = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        try pretty.write(to: url, options: .atomic)
        return url
    }

    func lastProjectParent() -> String {
        let stored = UserDefaults.standard.string(forKey: "lastProjectParent") ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ProjectLayout.defaultParent
    }

    func applyFolderToJob(_ job: inout ExportJob, url: URL) {
        var email = url
        if url.lastPathComponent != ProjectLayout.emailDir {
            let nested = url.appendingPathComponent(ProjectLayout.emailDir)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir), isDir.boolValue {
                email = nested
            }
        }
        job.outputDir = email.path
        job.projectDir = ProjectLayout.inferProjectRoot(from: email.path)
        if let data = try? email.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            job.bookmark = data.base64EncodedString()
        }
    }

    func deleteJob(id: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        let name = jobs[idx].name
        jobs.remove(at: idx)
        save()
        status = "Removed “\(name)”"
    }
}
