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
    var onEditMailbox: (String) -> Void = { _ in }
    @State private var busy = false
    @State private var openDetailsID: String?
    @State private var sessionResults: [String: SessionExportResult] = [:]
    @State private var lastDurations: [String: TimeInterval] = [:]
    @State private var runStartedAt: Date?
    @State private var elapsedSeconds: TimeInterval = 0
    @State private var runningJobID: String?
    @State private var tick: Timer?
    @State private var clearConfirmJob: ExportJob?
    @State private var removeConfirmJob: ExportJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    run(jobID: nil)
                } label: {
                    Text(busy ? "Exporting…" : "Export All")
                }
                .disabled(busy || store.jobs.isEmpty || hasAnyMissingFolder)
                .keyboardShortcut(.defaultAction)
                .help(hasAnyMissingFolder ? "One or more mailboxes have a missing export folder" : "Export all mailboxes")
            }
            .padding(.top, 4)

            if store.jobs.isEmpty {
                Text("No mailboxes yet. Add one in the Mailboxes tab.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                            onRemoveMailbox: { removeConfirmJob = job },
                            onEditMailbox: { onEditMailbox(job.id) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { stopTicker() }
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
        .confirmationDialog(
            "Remove Mailbox?",
            isPresented: Binding(
                get: { removeConfirmJob != nil },
                set: { if !$0 { removeConfirmJob = nil } }
            ),
            presenting: removeConfirmJob
        ) { job in
            Button("Remove Mailbox", role: .destructive) {
                removeMailbox(job)
            }
            Button("Cancel", role: .cancel) {
                removeConfirmJob = nil
            }
        } message: { job in
            Text(
                "Are you sure you want to remove “\(job.name)” from MailExporter?\n\nExported emails in \(job.outputDir) will not be deleted."
            )
        }
    }

    private func removeMailbox(_ job: ExportJob) {
        removeConfirmJob = nil
        store.deleteJob(id: job.id)
        sessionResults.removeValue(forKey: job.id)
        lastDurations.removeValue(forKey: job.id)
        if openDetailsID == job.id {
            openDetailsID = nil
        }
        if runningJobID == job.id {
            runningJobID = nil
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
                        store.needsFullDiskAccess = true
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
    var onRemoveMailbox: () -> Void
    var onEditMailbox: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.body.weight(.medium))

                switch folderStatus {
                case .exists:
                    Text("To: \(job.outputDir)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                case .moved(let suggestedURL):
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Folder moved to: \(suggestedURL.path)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            Button("Use Found Location") {
                                onUseFoundLocation(suggestedURL)
                            }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Choose Other…") {
                                onChooseFolder()
                            }
                            .font(.caption)
                            .controlSize(.small)

                            Button("Remove Mailbox", role: .destructive) {
                                onRemoveMailbox()
                            }
                            .font(.caption)
                            .controlSize(.small)
                        }
                    }

                case .inTrash(let trashURL):
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill")
                                .foregroundStyle(.red)
                            Text("Folder was moved to Trash: \(job.outputDir)")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            Button("Choose New Folder…") {
                                onChooseFolder()
                            }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Reveal in Trash") {
                                NSWorkspace.shared.activateFileViewerSelecting([trashURL])
                            }
                            .font(.caption)
                            .controlSize(.small)

                            Button("Remove Mailbox", role: .destructive) {
                                onRemoveMailbox()
                            }
                            .font(.caption)
                            .controlSize(.small)
                        }
                    }

                case .notFound(let candidateURL):
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("Folder not found: \(job.outputDir)")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            if let candidate = candidateURL {
                                Text("Found match: \(candidate.path)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("Use This Folder") {
                                    onUseFoundLocation(candidate)
                                }
                                .font(.caption)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            Button("Remove Mailbox", role: .destructive) {
                                onRemoveMailbox()
                            }
                            .font(.caption)
                            .controlSize(.small)
                        }
                    }
                }

                if let progressLabel, isRunningThis {
                    Text("Exporting… \(progressLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if let result {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(result.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
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
                                ScrollView {
                                    Text(result.detail)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                }
                                .frame(minWidth: 360, idealWidth: 420, maxWidth: 520, minHeight: 120, maxHeight: 320)
                            }
                        }
                        if let pane = MailAccessProbe.settingsPane(
                            for: result.summary + "\n" + result.detail
                        ) {
                            Button(pane.buttonTitle) {
                                pane.open()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEditMailbox)
            .help("Double-click to edit in Mailboxes")

            if folderStatus.isValidForExport {
                Button("Show in Finder", action: onShowInFinder)
            } else {
                Button("Choose Folder…", action: onChooseFolder)
                    .buttonStyle(.bordered)
            }

            if debugMode && folderStatus.isValidForExport {
                Button("Clear Target", role: .destructive, action: onClearTarget)
                    .disabled(busy)
            }

            Button(role: .destructive, action: onRemoveMailbox) {
                Label("Remove", systemImage: "trash")
            }
            .help("Remove Mailbox")
            .disabled(busy)

            Button(action: onExport) {
                Text("Export")
            }
            .disabled(busy || !folderStatus.isValidForExport)
            .help(folderStatus.isValidForExport ? "Export this mailbox" : "Choose a valid folder before exporting")
        }
        .padding(.vertical, 4)
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

            Button("Edit in Mailboxes", action: onEditMailbox)

            Divider()

            Button("Remove Mailbox", role: .destructive, action: onRemoveMailbox)
        }
    }
}
