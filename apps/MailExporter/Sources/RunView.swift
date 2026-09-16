import AppKit
import UserNotifications
import SwiftUI

private struct SessionExportResult {
    var summary: String
    var detail: String
    var durationSeconds: TimeInterval?
}

private enum DurationFormat {
    static func short(_ seconds: TimeInterval) -> String {
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

struct RunView: View {
    @EnvironmentObject private var store: JobsStore
    @EnvironmentObject private var prefs: AppPreferences
    @State private var busy = false
    @State private var openDetailsID: String?
    @State private var sessionResults: [String: SessionExportResult] = [:]
    @State private var lastDurations: [String: TimeInterval] = [:]
    @State private var runStartedAt: Date?
    @State private var elapsedSeconds: TimeInterval = 0
    @State private var runningJobID: String?
    @State private var tick: Timer?
    @State private var clearConfirmJob: ExportJob?
    @State private var editor: JobEditorPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Export")
                    .font(.title2.weight(.semibold))
                Spacer()
                if busy {
                    Text(progressLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button {
                    editor = .add
                } label: {
                    Label("Add Export", systemImage: "plus")
                }
                .disabled(busy)
                Button {
                    run(jobID: nil)
                } label: {
                    Text(busy ? "Exporting…" : "Export All")
                }
                .disabled(busy || store.jobs.isEmpty || hasAnyMissingFolder)
                .keyboardShortcut(.defaultAction)
                .help(hasAnyMissingFolder ? "One or more exports have a missing folder" : "Export all jobs")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if store.jobs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No exports yet.")
                        .foregroundStyle(.secondary)
                    Button("Add Export") {
                        editor = .add
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 16)
            } else {
                List {
                    ForEach(store.jobs) { job in
                        let status = store.folderStatus(for: job)
                        ExportJobRow(
                            job: job,
                            folderStatus: status,
                            result: sessionResults[job.id],
                            busy: busy,
                            debugMode: prefs.debugMode,
                            isRunningThis: busy && (runningJobID == nil || runningJobID == job.id),
                            progressLabel: (busy && (runningJobID == nil || runningJobID == job.id))
                                ? rowProgressLabel(for: job.id) : nil,
                            isDetailsOpen: Binding(
                                get: { openDetailsID == job.id },
                                set: { openDetailsID = $0 ? job.id : nil }
                            ),
                            onExport: { run(jobID: job.id) },
                            onShowInFinder: { showInFinder(job.outputDir) },
                            onChooseFolder: { store.promptChooseFolder(for: job.id) },
                            onUseFoundLocation: { url in
                                store.updateOutputDir(for: job.id, newPath: url.path)
                            },
                            onClearTarget: { clearConfirmJob = job },
                            onEdit: { editor = .edit(id: job.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 56)
            }

            DraftDropZone()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { stopTicker() }
        .sheet(item: $editor) { item in
            JobEditorSheet(
                presentation: item,
                initialJob: {
                    if case .edit(let jobID) = item {
                        return store.jobs.first { $0.id == jobID }
                    }
                    return nil
                }()
            )
            .environmentObject(store)
        }
        .confirmationDialog(
            "Clear Target Folder?",
            isPresented: Binding(
                get: { clearConfirmJob != nil },
                set: { if !$0 { clearConfirmJob = nil } }
            ),
            presenting: clearConfirmJob
        ) { job in
            Button("Clear Target", role: .destructive) {
                clearTarget(for: job)
            }
            Button("Cancel", role: .cancel) {
                clearConfirmJob = nil
            }
        } message: { job in
            Text(
                "Delete all exported .eml files in:\n\(job.outputDir)\n\nThe next export will rewrite every matching message."
            )
        }
    }

    private var hasAnyMissingFolder: Bool {
        store.jobs.contains { !store.folderStatus(for: $0).isValidForExport }
    }

    private func showInFinder(_ rawPath: String) {
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func clearTarget(for job: ExportJob) {
        clearConfirmJob = nil
        let dir = (job.outputDir as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        var removed = 0
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            sessionResults[job.id] = SessionExportResult(
                summary: "Target folder missing",
                detail: url.path,
                durationSeconds: nil
            )
            return
        }
        do {
            let items = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for item in items {
                let name = item.lastPathComponent
                if name.lowercased().hasSuffix(".eml") {
                    try fm.removeItem(at: item)
                    removed += 1
                }
            }
            let state = url.appendingPathComponent(".exported-ids.json")
            if fm.fileExists(atPath: state.path) {
                try fm.removeItem(at: state)
            }
            sessionResults[job.id] = SessionExportResult(
                summary: removed == 1
                    ? "Cleared 1 message from target"
                    : "Cleared \(removed) messages from target",
                detail: "Removed \(removed) .eml file(s) and export state from\n\(url.path)",
                durationSeconds: nil
            )
            store.status = "Cleared \(job.name) target"
        } catch {
            sessionResults[job.id] = SessionExportResult(
                summary: "Clear failed",
                detail: error.localizedDescription,
                durationSeconds: nil
            )
        }
    }

    private var progressLabel: String {
        var parts = [DurationFormat.short(elapsedSeconds)]
        if let est = estimateTotal(for: runningJobID) {
            let left = max(0, est - elapsedSeconds)
            if elapsedSeconds < 1.5 {
                parts.append("est. \(DurationFormat.short(est))")
            } else if left > 0.5 {
                parts.append("~\(DurationFormat.short(left)) left")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func rowProgressLabel(for jobID: String) -> String? {
        guard busy else { return nil }
        if let runningJobID, runningJobID != jobID { return nil }
        return progressLabel
    }

    private func estimateTotal(for jobID: String?) -> TimeInterval? {
        if let jobID, let d = lastDurations[jobID] { return d }
        if jobID == nil {
            let ids = store.jobs.map(\.id)
            let known = ids.compactMap { lastDurations[$0] }
            if !known.isEmpty { return known.reduce(0, +) }
            if let all = lastDurations["*"] { return all }
        }
        return lastDurations["*"]
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

    private func run(jobID: String?) {
        let moved = store.detectMovedTargetFolders(jobID: jobID)
        if !moved.isEmpty {
            for m in moved {
                notify("Moved folder detected for “\(m.job.name)”: updated to \(m.newPath)")
            }
        }

        let targetJobs = (jobID != nil) ? store.jobs.filter { $0.id == jobID } : store.jobs
        for job in targetJobs {
            let status = store.folderStatus(for: job)
            if !status.isValidForExport {
                let alert = NSAlert()
                alert.messageText = "Cannot Export “\(job.name)”"
                alert.informativeText = "The target export folder was not found:\n\(job.outputDir)\n\nPlease choose a valid export folder before exporting."
                alert.alertStyle = .warning
                alert.runModal()
                store.status = "Export cancelled: folder missing for “\(job.name)”"
                return
            }
            try? store.prepareOutputDirectory(for: job)
        }

        store.save()
        busy = true
        runningJobID = jobID
        startTicker()
        let root = store.projectRoot
        let config = store.configURL
        var args = ["export"]
        if let jobID {
            args += ["--job-id", jobID]
        }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try EngineBridge.run(
                    projectRoot: root,
                    arguments: args,
                    configPath: config
                )
                let duration = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    stopTicker()
                    busy = false
                    runningJobID = nil
                    store.needsFullDiskAccess = false
                    recordDuration(duration, jobID: jobID)
                    applyResult(result, focusedJobID: jobID, duration: duration)
                    store.reload()
                    notify("\(result.line) · \(DurationFormat.short(duration))")
                }
            } catch {
                let duration = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    stopTicker()
                    busy = false
                    runningJobID = nil
                    let message = error.localizedDescription
                    if MailAccessProbe.looksLikeFullDiskDenial(message) {
                        store.flagFullDiskAccessRequired()
                    }
                    markFailed(jobID: jobID, message: message, duration: duration)
                    store.status = message
                    notify(message)
                }
            }
        }
    }

    private func recordDuration(_ duration: TimeInterval, jobID: String?) {
        if let jobID {
            lastDurations[jobID] = duration
        } else {
            lastDurations["*"] = duration
            // Spread across jobs when we only know the combined time.
            let n = max(1, store.jobs.count)
            let each = duration / Double(n)
            for job in store.jobs {
                if lastDurations[job.id] == nil {
                    lastDurations[job.id] = each
                }
            }
        }
    }

    private func markFailed(jobID: String?, message: String, duration: TimeInterval) {
        let targets: [String]
        if let jobID {
            targets = [jobID]
        } else {
            targets = store.jobs.map(\.id)
        }
        for id in targets {
            sessionResults[id] = SessionExportResult(
                summary: "Export failed · \(DurationFormat.short(duration))",
                detail: message,
                durationSeconds: duration
            )
        }
    }

    private func applyResult(
        _ result: EngineResult,
        focusedJobID: String?,
        duration: TimeInterval
    ) {
        store.status = result.line
        let timeSuffix = " · \(DurationFormat.short(duration))"
        if let data = result.rawJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = obj["results"] as? [[String: Any]]
        {
            let per = results.isEmpty ? duration : duration / Double(results.count)
            for item in results {
                guard let id = item["id"] as? String else { continue }
                let summary = ((item["line"] as? String) ?? result.line) + timeSuffix
                let detail: String
                if let pretty = try? JSONSerialization.data(
                    withJSONObject: item,
                    options: [.prettyPrinted, .sortedKeys]
                ),
                    let text = String(data: pretty, encoding: .utf8)
                {
                    detail = text
                } else {
                    detail = summary
                }
                sessionResults[id] = SessionExportResult(
                    summary: summary,
                    detail: detail,
                    durationSeconds: per
                )
                lastDurations[id] = per
            }
            return
        }

        if let focusedJobID {
            sessionResults[focusedJobID] = SessionExportResult(
                summary: result.line + timeSuffix,
                detail: result.rawJSON.isEmpty ? result.line : result.rawJSON,
                durationSeconds: duration
            )
        }
    }

    private func notify(_ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = "MailExporter"
            content.body = body
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(req, withCompletionHandler: nil)
        }
    }
}

private struct ExportJobRow: View {
    let job: ExportJob
    let folderStatus: FolderStatus
    let result: SessionExportResult?
    let busy: Bool
    let debugMode: Bool
    let isRunningThis: Bool
    let progressLabel: String?
    @Binding var isDetailsOpen: Bool
    var onExport: () -> Void
    var onShowInFinder: () -> Void
    var onChooseFolder: () -> Void
    var onUseFoundLocation: (URL) -> Void
    var onClearTarget: () -> Void
    var onEdit: () -> Void

    private var statusCaption: String {
        if let progressLabel, isRunningThis {
            return "Exporting… \(progressLabel)"
        }
        if let result {
            return result.summary
        }
        switch folderStatus {
        case .exists:
            return job.outputDir
        case .moved(let suggestedURL):
            return "Folder moved to \(suggestedURL.path)"
        case .inTrash:
            return "Folder is in Trash"
        case .notFound(let candidateURL):
            if let candidate = candidateURL {
                return "Folder not found — match: \(candidate.path)"
            }
            return "Folder not found"
        }
    }

    private var statusColor: Color {
        if isRunningThis { return .secondary }
        switch folderStatus {
        case .exists:
            return .secondary
        case .moved:
            return .orange
        case .inTrash, .notFound:
            return .red
        }
    }

    private var detailsText: String {
        if let result { return result.detail }
        return statusCaption
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                if case .moved = folderStatus {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if case .inTrash = folderStatus {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.red)
                } else if case .notFound = folderStatus {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Text(job.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
                    .layoutPriority(-1)

                Button {
                    isDetailsOpen.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Details")
                .popover(isPresented: $isDetailsOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView {
                            Text(detailsText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minWidth: 360, idealWidth: 420, maxWidth: 520, minHeight: 80, maxHeight: 280)
                        if let pane = MailAccessProbe.settingsPane(for: detailsText) {
                            Button(pane.buttonTitle) {
                                pane.open()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    .padding(12)
                }
                .opacity(result != nil || isRunningThis ? 1 : 0)
                .disabled(result == nil && !isRunningThis)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)
            .help("Double-click to edit")

            inlineRecoveryButtons

            HStack(spacing: 10) {
                if folderStatus.isValidForExport {
                    Button("Show in Finder", action: onShowInFinder)
                } else {
                    Button("Choose Folder…", action: onChooseFolder)
                        .buttonStyle(.bordered)
                }

                Button("Edit", action: onEdit)
                    .disabled(busy)

                if debugMode && folderStatus.isValidForExport {
                    Button("Clear Target", role: .destructive, action: onClearTarget)
                        .disabled(busy)
                }

                Button("Export", action: onExport)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !folderStatus.isValidForExport)
                    .help(folderStatus.isValidForExport ? "Export this job" : "Choose a valid folder before exporting")
            }
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .overlay(alignment: .bottom) {
            if isRunningThis {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 3)
                    .padding(.horizontal, 4)
            }
        }
        .contextMenu {
            Button("Export") {
                onExport()
            }
            .disabled(!folderStatus.isValidForExport || busy)

            if folderStatus.isValidForExport {
                Button("Show in Finder", action: onShowInFinder)
            } else {
                Button("Choose Folder…", action: onChooseFolder)
            }

            Button("Edit", action: onEdit)
        }
    }

    @ViewBuilder
    private var inlineRecoveryButtons: some View {
        switch folderStatus {
        case .moved(let suggestedURL):
            Button("Use Found") {
                onUseFoundLocation(suggestedURL)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        case .inTrash(let trashURL):
            Button("Reveal in Trash") {
                NSWorkspace.shared.activateFileViewerSelecting([trashURL])
            }
            .controlSize(.small)
        case .notFound(let candidateURL):
            if let candidate = candidateURL {
                Button("Use Match") {
                    onUseFoundLocation(candidate)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        case .exists:
            EmptyView()
        }
    }
}
