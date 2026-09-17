import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Always-visible Markdown → Apple Mail draft drop zone (never sends).
struct DraftDropZone: View {
    @ObservedObject private var inbox = ComposeInbox.shared
    @ObservedObject private var runner = ComposeRunner.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dropZone
                .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 120)

            if let lastResult = runner.lastResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lastResult.summary)
                        .font(.callout.weight(.medium))
                    Text(lastResult.detail)
                        .font(.caption)
                        .foregroundStyle(lastResult.ok ? Color.secondary : Color.primary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    if let pane = MailAccessProbe.settingsPane(
                        for: lastResult.summary + "\n" + lastResult.detail
                    ) {
                        Button(pane.buttonTitle) {
                            pane.open()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { runner.drainInbox() }
        .onChange(of: inbox.generation) { _ in runner.drainInbox() }
        .onChange(of: runner.busy) { isBusy in
            if !isBusy { runner.drainInbox() }
        }
    }

    private var recentDropsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent files")
                .font(.caption.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(inbox.recentDrops.prefix(6)) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text(Self.timeFormatter.string(from: item.droppedAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack {
            shape.fill(isTargeted ? Color.accentColor.opacity(0.14) : dropWellFill)

            shape
                .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.55 : 0.18), lineWidth: 6)
                .blur(radius: 5)
                .offset(y: 2)
                .mask(
                    shape.fill(
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.65)
                        )
                    )
                )
                .allowsHitTesting(false)

            wellContent
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            shape.strokeBorder(
                isTargeted
                    ? Color.accentColor
                    : Color.primary.opacity(colorScheme == .dark ? 0.5 : 0.38),
                style: StrokeStyle(lineWidth: 1.75, dash: [5, 4])
            )
            .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var wellContent: some View {
        HStack(spacing: 14) {
            dropMessageIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(runner.busy ? "Working…" : "Drop .md email files here")
                    .font(.headline)
                Text("Opens an Apple Mail draft — never sends")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button(action: chooseFiles) {
                    Label("Choose Files…", systemImage: "doc")
                        .labelStyle(.trailingIcon)
                }
                .disabled(runner.busy)
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
            if !inbox.recentDrops.isEmpty {
                recentDropsPanel
                    .frame(width: 196)
            }
        }
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
        if panel.runModal() == .OK {
            runner.process(urls: panel.urls, alreadyRecorded: false)
        }
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
            runner.process(urls: urls, alreadyRecorded: false)
        }
        return true
    }
}
