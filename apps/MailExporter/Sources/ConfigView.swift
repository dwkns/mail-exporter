import AppKit
import SwiftUI

enum JobEditorPresentation: Identifiable, Hashable {
    case add
    case edit(id: String)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let jobID): return "edit-\(jobID)"
        }
    }

    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .add: return "New Project"
        case .edit: return "Edit Project"
        }
    }
}

struct JobEditorSheet: View {
    @EnvironmentObject private var store: JobsStore
    @Environment(\.dismiss) private var dismiss

    let presentation: JobEditorPresentation
    @State private var draft: ExportJob
    @State private var projectParent: String
    @State private var previewText: String = ""
    @State private var busy = false
    @State private var elapsedSeconds: TimeInterval = 0
    @State private var runStartedAt: Date?
    @State private var tick: Timer?
    @State private var confirmDelete = false

    init(presentation: JobEditorPresentation, initialJob: ExportJob?) {
        self.presentation = presentation
        if let initialJob {
            _draft = State(initialValue: initialJob)
            if let project = initialJob.projectDir, !project.isEmpty {
                _projectParent = State(
                    initialValue: URL(fileURLWithPath: project).deletingLastPathComponent().path
                )
            } else {
                let inferred = ProjectLayout.inferProjectRoot(from: initialJob.outputDir)
                _projectParent = State(
                    initialValue: URL(fileURLWithPath: inferred).deletingLastPathComponent().path
                )
            }
        } else {
            _draft = State(initialValue: ExportJob())
            _projectParent = State(initialValue: ProjectLayout.defaultParent)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(presentation.title)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            SmartMailboxEditor(
                job: $draft,
                isAdd: presentation.isAdd,
                projectParent: $projectParent,
                folderStatus: store.folderStatus(for: draft),
                onUseFoundLocation: { url in
                    applyFolder(url)
                },
                previewText: $previewText,
                busy: $busy,
                elapsedLabel: busy ? Self.formatDuration(elapsedSeconds) : nil,
                onPreview: { preview() },
                onBrowse: { browse() },
                onBrowseParent: { browseParent() }
            )

            Divider()

            HStack(spacing: 12) {
                if !presentation.isAdd {
                    Button("Delete", role: .destructive) {
                        confirmDelete = true
                    }
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    saveDraft()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .help(saveHelp)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 580)
        .onAppear {
            if presentation.isAdd {
                projectParent = store.lastProjectParent()
            }
        }
        .onDisappear { stopTicker() }
        .confirmationDialog(
            "Delete Export?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteJob(id: draft.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Remove “\(draft.name)” from MailExporter?\n\nExported emails in \(draft.outputDir) will not be deleted."
            )
        }
    }

    private var canSave: Bool {
        let nameOK = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if presentation.isAdd {
            return nameOK && !JobsStore.isForbiddenOutputDir(projectParent)
        }
        let folder = store.folderStatus(for: draft)
        return nameOK && folder.isValidForExport && !JobsStore.isForbiddenOutputDir(draft.outputDir)
    }

    private var saveHelp: String {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Name this project"
        }
        if presentation.isAdd {
            if JobsStore.isForbiddenOutputDir(projectParent) {
                return "Choose a parent folder that is not / or inside ~/Library/Mail"
            }
            return "Create the project folder and save the rules"
        }
        if JobsStore.isForbiddenOutputDir(draft.outputDir) {
            return "Choose a folder that is not / or inside ~/Library/Mail"
        }
        if !store.folderStatus(for: draft).isValidForExport {
            return "Choose a real export folder before saving"
        }
        return "Save this project"
    }

    private func saveDraft() {
        if presentation.isAdd {
            do {
                let created = try store.createProject(named: draft.name, parent: projectParent)
                var next = draft
                next.outputDir = created.outputDir
                next.projectDir = created.projectDir
                next.bookmark = created.bookmark
                store.upsertJob(next)
                dismiss()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t create the project folder"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
            return
        }
        store.upsertJob(draft)
        dismiss()
    }

    private func browseParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Projects are created inside this folder"
        if panel.runModal() == .OK, let url = panel.url {
            if JobsStore.isForbiddenOutputDir(url.path) {
                let alert = NSAlert()
                alert.messageText = "That folder can’t be used"
                alert.informativeText = "Pick a folder that is not the disk root and not inside ~/Library/Mail."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            projectParent = url.path
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            applyFolder(url)
        }
    }

    private func applyFolder(_ url: URL) {
        if JobsStore.isForbiddenOutputDir(url.path) {
            let alert = NSAlert()
            alert.messageText = "That folder can’t be used"
            alert.informativeText = "Pick a folder that is not the disk root and not inside ~/Library/Mail. MailExporter never writes into Apple Mail’s store."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        var next = draft
        store.applyFolderToJob(&next, url: url)
        draft = next
    }

    private func preview() {
        busy = true
        previewText = ""
        startTicker()
        let root = store.projectRoot
        let jobID = draft.id
        let started = Date()
        let config: URL
        do {
            config = try store.temporaryConfigURL(including: draft)
        } catch {
            stopTicker()
            busy = false
            previewText = "Couldn’t check matches"
            store.status = error.localizedDescription
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: config) }
            do {
                let result = try EngineSession.shared.export(
                    projectRoot: root,
                    configPath: config,
                    jobID: jobID,
                    dryRun: true
                )
                let duration = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    stopTicker()
                    busy = false
                    store.needsFullDiskAccess = false
                    let time = Self.formatDuration(duration)
                    if let n = result.matchCount {
                        let count = n == 1 ? "1 message matches" : "\(n) messages match"
                        previewText = "\(count) · \(time)"
                        if let samples = Self.sampleSubjects(from: result), !samples.isEmpty {
                            previewText += "\n" + samples
                        }
                    } else {
                        previewText = "\(result.line) · \(time)"
                    }
                    store.status = result.line
                }
            } catch {
                let duration = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    stopTicker()
                    busy = false
                    let message = error.localizedDescription
                    if MailAccessProbe.looksLikeFullDiskDenial(message) {
                        store.flagFullDiskAccessRequired()
                    }
                    previewText = "Couldn’t check matches · \(Self.formatDuration(duration))"
                    store.status = message
                }
            }
        }
    }

    private func startTicker() {
        stopTicker()
        elapsedSeconds = 0
        runStartedAt = Date()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            if let start = runStartedAt {
                elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
        if let tick {
            RunLoop.main.add(tick, forMode: .common)
        }
    }

    private func stopTicker() {
        tick?.invalidate()
        tick = nil
    }

    private static func sampleSubjects(from result: EngineResult) -> String? {
        guard let data = result.rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let first = results.first,
              let samples = first["samples"] as? [String],
              !samples.isEmpty
        else { return nil }
        return samples.prefix(5).map { "• \($0)" }.joined(separator: "\n")
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%dm %02ds", m, s)
    }
}

struct SmartMailboxEditor: View {
    @Binding var job: ExportJob
    var isAdd: Bool
    @Binding var projectParent: String
    var folderStatus: FolderStatus
    var onUseFoundLocation: (URL) -> Void
    @Binding var previewText: String
    @Binding var busy: Bool
    var elapsedLabel: String?
    var onPreview: () -> Void
    var onBrowse: () -> Void
    var onBrowseParent: () -> Void

    private var createdProjectPath: String {
        let parent = (projectParent as NSString).expandingTildeInPath
        let name = ProjectLayout.sanitizedFolderName(job.name)
        return (parent as NSString).appendingPathComponent(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Name:")
                    .frame(width: 150, alignment: .trailing)
                TextField("Name", text: $job.name)
                    .textFieldStyle(.roundedBorder)
            }

            if isAdd {
                HStack(alignment: .firstTextBaseline) {
                    Text("Create in:")
                        .frame(width: 150, alignment: .trailing)
                    TextField("Parent folder", text: $projectParent)
                        .textFieldStyle(.roundedBorder)
                    Button(action: onBrowseParent) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.trailingIcon)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Spacer().frame(width: 150)
                    Text("Creates \(createdProjectPath) with Email, Documents, Notes, _archive, STATUS.md, and how_to_use.md. Export, then tell the AI to read that folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Email folder:")
                        .frame(width: 150, alignment: .trailing)
                    TextField("Choose a folder", text: $job.outputDir)
                        .textFieldStyle(.roundedBorder)
                    Button(action: onBrowse) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.trailingIcon)
                    }
                }
            }

            switch folderStatus {
            case .exists, .unset:
                EmptyView()
            case .moved(let suggestedURL):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Spacer().frame(width: 150)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Folder moved to: \(suggestedURL.path)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Use Found Folder") {
                        onUseFoundLocation(suggestedURL)
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            case .inTrash(let trashURL):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Spacer().frame(width: 150)
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.red)
                    Text("Folder is currently in macOS Trash.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Reveal in Trash") {
                        NSWorkspace.shared.activateFileViewerSelecting([trashURL])
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            case .notFound(let candidateURL):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Spacer().frame(width: 150)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Folder not found on disk")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if let candidate = candidateURL {
                        Text("— Found match: \(candidate.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Use Match") {
                            onUseFoundLocation(candidate)
                        }
                        .font(.caption)
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 6) {
                Text("Contains messages that match")
                Picker("", selection: $job.conjunction) {
                    Text("all").tag("all")
                    Text("any").tag("any")
                }
                .labelsHidden()
                .frame(width: 72)
                Text("of the following groups:")
                Spacer(minLength: 0)
                Button {
                    job.groups.append(MatchGroup(conjunction: "any"))
                } label: {
                    Label("Add Group", systemImage: "plus")
                        .labelStyle(.trailingIcon)
                }
                .buttonStyle(.borderless)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(job.groups.indices), id: \.self) { idx in
                        RuleGroupCard(
                            group: $job.groups[idx],
                            groupIndex: idx,
                            canRemove: job.groups.count > 1,
                            onRemove: {
                                let id = job.groups[idx].id
                                job.groups.removeAll { $0.id == id }
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Include messages from Bin", isOn: $job.includeBin)
                    Toggle("Include messages from Sent", isOn: $job.includeSent)
                    Toggle("Also export the rest of the thread", isOn: $job.includeThread)
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 8)

                if busy, let elapsedLabel {
                    Text("Checking… \(elapsedLabel)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                } else if !previewText.isEmpty {
                    Text(previewText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                Button(action: onPreview) {
                    Text(busy ? "Checking…" : "Check Matches")
                }
                .disabled(busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RuleGroupCard: View {
    @Binding var group: MatchGroup
    var groupIndex: Int
    var canRemove: Bool
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Group \(groupIndex + 1)")
                    .font(.headline)
                Text("— match")
                Picker("", selection: $group.conjunction) {
                    Text("any").tag("any")
                    Text("all").tag("all")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 72)
                Text("of these conditions:")
                Spacer()
                if canRemove {
                    Button("Remove Group", role: .destructive, action: onRemove)
                        .buttonStyle(.borderless)
                }
            }

            VStack(spacing: 0) {
                ForEach($group.conditions) { $clause in
                    ConditionRow(
                        clause: $clause,
                        canRemove: group.conditions.count > 1,
                        onRemove: {
                            group.conditions.removeAll { $0.id == clause.id }
                        },
                        onAdd: {
                            group.conditions.append(MatchClause())
                        }
                    )
                    if clause.id != group.conditions.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

struct ConditionRow: View {
    @Binding var clause: MatchClause
    var canRemove: Bool
    var onRemove: () -> Void
    var onAdd: () -> Void

    private let fields: [(label: String, key: String)] = [
        ("Entire message", "entire"),
        ("From", "from"),
        ("To", "to"),
        ("Cc", "cc"),
        ("Any Recipient", "recipient"),
        ("Subject", "subject"),
        ("Body", "body"),
        ("Date Received", "date"),
    ]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                Self.dateFormatter.date(from: clause.date) ?? Date()
            },
            set: { clause.date = Self.dateFormatter.string(from: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $clause.field) {
                ForEach(fields, id: \.key) { item in
                    Text(item.label).tag(item.key)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)

            Picker("", selection: $clause.op) {
                if clause.field == "date" {
                    Text("is after").tag("after")
                    Text("is before").tag("before")
                } else {
                    Text("contains").tag("contains")
                    Text("does not contain").tag("does_not_contain")
                    Text("is equal to").tag("is")
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140)

            if clause.field == "date" {
                DatePicker("", selection: dateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $clause.value)
                    .textFieldStyle(.roundedBorder)
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .opacity(canRemove ? 1 : 0.35)

            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: clause.field) { newValue in
            if newValue == "date" {
                if clause.op != "after" && clause.op != "before" {
                    clause.op = "after"
                }
                if clause.date.isEmpty {
                    clause.date = Self.dateFormatter.string(from: Date())
                }
            } else if clause.op == "after" || clause.op == "before" {
                clause.op = "contains"
            }
        }
    }
}
