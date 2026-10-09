import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Always-visible Markdown → Apple Mail draft drop zone (never sends).
struct DraftDropZone: View {
    @ObservedObject private var inbox = ComposeInbox.shared
    @ObservedObject private var runner = ComposeRunner.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false
    @State private var dismissedOutcomeIDs: Set<UUID> = []
    @State private var bannerBright = false
    @State private var earlierExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dropZone
                .frame(maxWidth: .infinity, minHeight: 96, maxHeight: inbox.currentBatch == nil ? 120 : 360)

            if !inbox.earlierBatches.isEmpty {
                DisclosureGroup(isExpanded: $earlierExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(inbox.earlierBatches) { batch in
                            earlierBatch(batch)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Earlier drops")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { runner.drainInbox() }
        .onChange(of: inbox.generation) { _ in runner.drainInbox() }
        .onChange(of: runner.busy) { isBusy in
            if !isBusy { runner.drainInbox() }
        }
        .onChange(of: inbox.currentBatch?.id) { _ in
            dismissedOutcomeIDs = []
        }
        .onChange(of: runner.resultGeneration) { _ in
            guard hasVisibleFailure else { return }
            bannerBright = true
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.55)) {
                    bannerBright = false
                }
            }
        }
    }

    private var successCaption: String {
        if let result = runner.lastResult, result.ok, !result.summary.isEmpty {
            return result.summary
        }
        return "Draft opened in Mail"
    }

    private var hasVisibleFailure: Bool {
        guard let batch = inbox.currentBatch else { return false }
        return zip(batch.files, batch.outcomes).contains { _, outcome in
            !outcome.ok && !dismissedOutcomeIDs.contains(outcome.id)
        }
    }

    private func bannerText(for outcome: ComposeFileOutcome) -> String {
        let sentence = ComposeFailureCopy.banner(summary: "Compose failed", detail: outcome.detail)
        return "\(outcome.name): \(sentence)"
    }

    private func fileBanner(_ outcome: ComposeFileOutcome) -> some View {
        let text = bannerText(for: outcome)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(bannerBright ? Color.white : Color.red)
            Text(text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(bannerBright ? Color.white : Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                dismissedOutcomeIDs.insert(outcome.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(bannerBright ? Color.white : Color.red)
            .accessibilityLabel("Dismiss")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(bannerBright ? 0.95 : 0.16))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private func earlierBatch(_ batch: DropBatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(batch.files) { file in
                Text(file.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            ForEach(Array(batch.outcomes.enumerated()), id: \.element.id) { _, outcome in
                if !outcome.ok {
                    Text(bannerText(for: outcome))
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack {
            shape.fill(isTargeted ? Color.accentColor.opacity(0.14) : dropWellFill)
            wellContent
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            shape.strokeBorder(
                isTargeted
                    ? Color.accentColor
                    : Color.primary.opacity(0.28),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var wellContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                dropMessageIcon
                VStack(alignment: .leading, spacing: 6) {
                    if let batch = inbox.currentBatch {
                        currentDrop(batch)
                    } else {
                        Text(runner.busy ? "Working…" : "Drop .md email files here")
                            .font(.headline)
                        Text("Opens an Apple Mail draft — never sends")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Choose Files") {
                        chooseFiles()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(runner.busy)
                    .help("Choose Markdown email files")
                    .accessibilityLabel("Choose Files")
                    if inbox.currentBatch != nil {
                        Button("Clear") {
                            dismissedOutcomeIDs.removeAll()
                            inbox.clearCurrentDisplay()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Clear")
                    }
                    if runner.busy {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Opening drafts…")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func currentDrop(_ batch: DropBatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(batch.files.enumerated()), id: \.element.id) { index, file in
                Text(file.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if index < batch.outcomes.count {
                    let outcome = batch.outcomes[index]
                    if !outcome.ok && !dismissedOutcomeIDs.contains(outcome.id) {
                        fileBanner(outcome)
                    }
                }
            }
            if batch.outcomes.isEmpty && runner.busy {
                Text("Working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !batch.outcomes.isEmpty && batch.outcomes.allSatisfy(\.ok) {
                Text(successCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dropMessageIcon: some View {
        ZStack(alignment: .top) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 28, weight: .medium))
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .offset(y: -10)
        }
        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
        .frame(width: 36, height: 40)
        .accessibilityHidden(true)
    }

    private var dropWellFill: Color {
        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, .utf8PlainText]
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes.append(md)
        }
        if let markdown = UTType(filenameExtension: "markdown") {
            panel.allowedContentTypes.append(markdown)
        }
        panel.prompt = "Open Drafts"
        panel.message = "Choose Markdown email files"
        if let drafts = firstDraftsFolder() {
            panel.directoryURL = drafts
        }
        if panel.runModal() == .OK {
            runner.process(urls: panel.urls)
        }
    }

    private func firstDraftsFolder() -> URL? {
        let storeURL = JobsStore.defaultConfigURL()
        guard let data = try? Data(contentsOf: storeURL),
              let doc = try? JSONDecoder().decode(JobsDocument.self, from: data)
        else { return nil }
        for job in doc.jobs {
            let raw = job.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let drafts = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                .appendingPathComponent("Drafts", isDirectory: true)
            if FileManager.default.fileExists(atPath: drafts.path) {
                return drafts
            }
        }
        return nil
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else {
                    url = nil
                }
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            runner.process(urls: urls)
        }
        return true
    }
}
