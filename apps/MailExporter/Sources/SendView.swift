import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SendView: View {
    @ObservedObject private var inbox = ComposeInbox.shared
    @ObservedObject private var runner = ComposeRunner.shared
    @State private var isTargeted = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send Messages")
                .font(.title2.weight(.semibold))
                .padding(.top, 4)

            Text("Drop Markdown email files here, or onto the MailExporter app icon. With In-Reply-To set, MailExporter replies when it can find that message.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                dropZone
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .frame(maxHeight: .infinity)

                recentDropsPanel
                    .frame(width: 280)
                    .frame(maxHeight: .infinity)
            }

            if let lastResult = runner.lastResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text(lastResult.summary)
                        .font(.body.weight(.medium))
                    Text(lastResult.detail)
                        .font(.caption)
                        .foregroundStyle(lastResult.ok ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                    if let pane = MailAccessProbe.settingsPane(
                        for: lastResult.summary + "\n" + lastResult.detail
                    ) {
                        Button(pane.buttonTitle) {
                            pane.open()
                        }
                        .buttonStyle(.link)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !runner.statusLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(runner.statusLines, id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }

            HStack {
                Button("Choose Files…") {
                    chooseFiles()
                }
                .disabled(runner.busy)
                Spacer()
                if runner.busy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Opening drafts…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { runner.drainInbox() }
        .onChange(of: inbox.generation) { _ in runner.drainInbox() }
        .onChange(of: runner.busy) { isBusy in
            if !isBusy { runner.drainInbox() }
        }
    }

    private var recentDropsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent files")
                .font(.headline)
            if inbox.recentDrops.isEmpty {
                Text("Dropped or chosen .md files will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(inbox.recentDrops) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text(Self.timeFormatter.string(from: item.droppedAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(item.url.deletingLastPathComponent().path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted
                    ? Color.accentColor.opacity(0.12)
                    : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [7, 5])
                )

            VStack(spacing: 10) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text(runner.busy ? "Working…" : "Drop .md email files here")
                    .font(.headline)
                Text("Same format as Make Mail Draft — front matter + Markdown body")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
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
