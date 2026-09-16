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
            header
            if store.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
            DraftDropZone()
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Export")
                .font(.title2.weight(.semibold))
            if busy {
                Text(progressLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Elapsed time for the current export")
            }
            Spacer(minLength: 12)
            HeaderActionButton(
                title: "New",
                symbol: "plus",
                tint: .blue,
                style: .quiet,
                enabled: !busy
            ) {
                editor = .add
            }
            .help("Add a new export")
            .accessibilityLabel("New export")

            HeaderActionButton(
                title: busy ? "Exporting…" : "Export",
                symbol: "tray.and.arrow.down.fill",
                tint: .accentColor,
                style: .prominent,
                enabled: !busy && !store.jobs.isEmpty && !hasAnyMissingFolder,
                spinning: busy
            ) {
                run(jobID: nil)
            }
            .keyboardShortcut(.defaultAction)
            .help(hasAnyMissingFolder ? "One or more exports have a missing folder" : "Export all jobs")
            .accessibilityLabel(busy ? "Exporting" : "Export all")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            JobGlyph(symbol: "tray.and.arrow.down.fill", tint: .accentColor, size: 52)
            VStack(spacing: 4) {
                Text("No exports yet")
                    .font(.title3.weight(.semibold))
                Text("Each export copies matching Mail messages into a folder on disk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HeaderActionButton(
                title: "New",
                symbol: "plus",
                tint: .blue,
                style: .quiet
            ) {
                editor = .add
            }
            .help("Add a new export")
            .accessibilityLabel("New export")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var jobList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(store.jobs.enumerated()), id: \.element.id) { index, job in
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
                        onEdit: {
                            editor = .edit(id: job.id)
                        }
                    )
                    if index < store.jobs.count - 1 {
                        Divider()
                            .padding(.leading, 62)
                            .padding(.trailing, 14)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct JobGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(tint.gradient)
            )
            .accessibilityHidden(true)
    }
}

private struct HeaderActionButton: View {
    enum Style {
        case quiet
        case prominent
    }

    let title: String
    let symbol: String
    let tint: Color
    var style: Style = .quiet
    var enabled: Bool = true
    var spinning: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if spinning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                            .frame(width: 28, height: 28)
                            .tint(style == .prominent ? Color.white : Color.secondary)
                    } else if style == .prominent {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.22))
                            )
                    } else {
                        JobGlyph(symbol: symbol, tint: tint, size: 28)
                    }
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style == .prominent ? Color.white : Color.primary)
            }
            .padding(.leading, 5)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        style == .quiet
                            ? Color(nsColor: .separatorColor).opacity(0.55)
                            : Color.white.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering && enabled ? 0.10 : 0))
            )
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.42)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }

    private var chipFill: AnyShapeStyle {
        switch style {
        case .prominent:
            return AnyShapeStyle(Color.accentColor.gradient)
        case .quiet:
            return AnyShapeStyle(
                hovering
                    ? Color.primary.opacity(0.06)
                    : Color(nsColor: .controlBackgroundColor)
            )
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

    @State private var hovering = false

    private static let identityTints: [Color] = [
        .blue, .teal, .indigo, .purple, .orange, .mint,
    ]

    private var identityTint: Color {
        let hash = job.id.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(hash) % Self.identityTints.count
        return Self.identityTints[index]
    }

    private var glyphTint: Color {
        switch folderStatus {
        case .exists:
            return identityTint
        case .moved:
            return .orange
        case .inTrash, .notFound:
            return .red
        }
    }

    private var glyphSymbol: String {
        switch folderStatus {
        case .exists:
            return "tray.and.arrow.down.fill"
        case .moved:
            return "questionmark.folder.fill"
        case .inTrash:
            return "trash.fill"
        case .notFound:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String? {
        if isRunningThis {
            if let progressLabel { return progressLabel }
            return "Exporting…"
        }
        if let result { return result.summary }
        switch folderStatus {
        case .exists:
            return nil
        case .moved:
            return "Folder moved"
        case .inTrash:
            return "In Trash"
        case .notFound:
            return "Folder missing"
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

    private var pathColor: Color {
        switch folderStatus {
        case .exists:
            return .secondary
        case .moved:
            return .orange
        case .inTrash, .notFound:
            return .red
        }
    }

    private var displayPath: String {
        let home = NSHomeDirectory()
        let expanded = (job.outputDir as NSString).expandingTildeInPath
        if expanded.hasPrefix(home) {
            return "~" + expanded.dropFirst(home.count)
        }
        return job.outputDir
    }

    private var detailsText: String {
        if let result { return result.detail }
        return job.outputDir
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                JobGlyph(symbol: glyphSymbol, tint: glyphTint)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 7) {
                        Text(job.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0)

                        if isRunningThis {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.72)
                                .frame(width: 12, height: 12)
                                .help("This export is running")
                        }

                        if let statusText {
                            Text(statusText)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        if result != nil, !isRunningThis {
                            detailsButton
                        }
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                        Text(displayPath)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(pathColor)
                    .lineLimit(1)
                    .help(job.outputDir)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)
            .help("Double-click to edit this export")

            HStack(spacing: 8) {
                inlineRecoveryButtons

                if folderStatus.isValidForExport {
                    Button(action: onShowInFinder) {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .accessibilityLabel("Show in Finder")
                    .help("Reveal the export folder in Finder")
                } else {
                    Button("Choose Folder…", action: onChooseFolder)
                        .accessibilityLabel("Choose Folder")
                }

                if debugMode && folderStatus.isValidForExport {
                    Button("Clear Target", role: .destructive, action: onClearTarget)
                        .disabled(busy)
                }

                Button("Export", action: onExport)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Export")
                    .disabled(busy || !folderStatus.isValidForExport)
                    .help(folderStatus.isValidForExport ? "Export this job" : "Choose a valid folder before exporting")
            }
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .background(rowFill)
        .onHover { hovering = $0 }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.name)
        .accessibilityValue(statusText ?? displayPath)
        .accessibilityHint("Double-click to edit this export")
    }

    private var rowFill: Color {
        hovering ? Color.primary.opacity(0.045) : .clear
    }

    private var detailsButton: some View {
        Button {
            isDetailsOpen.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
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
