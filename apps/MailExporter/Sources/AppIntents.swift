import AppIntents
import AppKit

struct ExportAllIntent: AppIntent {
    static var title: LocalizedStringResource = "Export All"
    static var description = IntentDescription("Run every MailExporter job that has a folder.")

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .mailExporterExportAll, object: nil)
        }
        return .result()
    }
}

struct ExportJobIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Job"
    static var description = IntentDescription("Export one MailExporter job by name.")

    @Parameter(title: "Job")
    var jobName: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .mailExporterExportJob,
                object: nil,
                userInfo: ["name": jobName]
            )
        }
        return .result()
    }
}

struct ShowFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Folder"
    static var description = IntentDescription("Reveal a MailExporter export folder in Finder.")

    @Parameter(title: "Job")
    var jobName: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .mailExporterShowFolder,
                object: nil,
                userInfo: ["name": jobName]
            )
        }
        return .result()
    }
}

struct OpenDraftIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Draft"
    static var description = IntentDescription("Open a Markdown file as an Apple Mail draft. Never sends.")

    @Parameter(title: "Markdown path")
    var path: String

    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        await MainActor.run {
            ComposeInbox.shared.enqueue([url])
        }
        return .result()
    }
}

struct NewExportIntent: AppIntent {
    static var title: LocalizedStringResource = "New Export"
    static var description = IntentDescription("Open the New Export sheet in MailExporter.")

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .mailExporterNewExport, object: nil)
        }
        return .result()
    }
}

struct MailExporterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExportAllIntent(),
            phrases: ["Export all with \(.applicationName)"],
            shortTitle: "Export All",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: ExportJobIntent(),
            phrases: ["Export job with \(.applicationName)"],
            shortTitle: "Export Job",
            systemImageName: "tray"
        )
        AppShortcut(
            intent: ShowFolderIntent(),
            phrases: ["Show MailExporter folder"],
            shortTitle: "Show Folder",
            systemImageName: "folder"
        )
        AppShortcut(
            intent: OpenDraftIntent(),
            phrases: ["Open MailExporter draft"],
            shortTitle: "Open Draft",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: NewExportIntent(),
            phrases: ["New export in \(.applicationName)"],
            shortTitle: "New Export",
            systemImageName: "plus"
        )
    }
}
