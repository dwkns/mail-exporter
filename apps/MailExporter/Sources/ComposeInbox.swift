import Foundation

struct DroppedFileRecord: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let droppedAt: Date

    init(url: URL, droppedAt: Date = Date()) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent
        self.droppedAt = droppedAt
    }
}

/// Queues Markdown files opened via Dock/Finder drop onto the app icon
/// (or `open -a`), so Send Messages can compose them.
final class ComposeInbox: ObservableObject {
    static let shared = ComposeInbox()

    @Published private(set) var pendingURLs: [URL] = []
    /// Bumped so SendView re-processes even if the same paths are dropped again.
    @Published private(set) var generation: UInt = 0
    @Published var wantsSendTab = false
    /// Most recent drop / choose / open batch (newest first), capped.
    @Published private(set) var recentDrops: [DroppedFileRecord] = []

    private let recentLimit = 40

    private init() {}

    func enqueue(_ urls: [URL]) {
        let md = Self.markdownURLs(from: urls)
        guard !md.isEmpty else { return }
        let apply = {
            self.recordDrops(md)
            // Append — never replace an undrained batch.
            self.pendingURLs.append(contentsOf: md)
            self.generation &+= 1
            self.wantsSendTab = true
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Record files chosen/dropped inside the Send tab (no pending queue).
    func recordDrops(_ urls: [URL]) {
        let md = Self.markdownURLs(from: urls)
        guard !md.isEmpty else { return }
        let now = Date()
        let records = md.map { DroppedFileRecord(url: $0, droppedAt: now) }
        recentDrops = Array((records + recentDrops).prefix(recentLimit))
    }

    func takePending() -> [URL] {
        let urls = pendingURLs
        pendingURLs = []
        return urls
    }

    var hasPending: Bool { !pendingURLs.isEmpty }

    private static func markdownURLs(from urls: [URL]) -> [URL] {
        urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "md" || ext == "markdown" || ext == "txt"
        }
    }
}

/// Always-on composer so Dock/Finder drops work even before Send Messages is visible.
final class ComposeRunner: ObservableObject {
    static let shared = ComposeRunner()

    @Published var busy = false
    @Published var lastResult: ComposeResult?
    @Published var statusLines: [String] = []

    private init() {}

    func drainInbox() {
        if busy { return }
        let inbox = ComposeInbox.shared
        let urls = inbox.takePending()
        guard !urls.isEmpty else { return }
        process(urls: urls, alreadyRecorded: true)
    }

    func process(urls: [URL], alreadyRecorded: Bool) {
        let md = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "md" || ext == "markdown" || ext == "txt"
        }
        guard !md.isEmpty, !busy else { return }
        let inbox = ComposeInbox.shared
        if !alreadyRecorded {
            inbox.recordDrops(md)
        }
        busy = true
        lastResult = nil
        let names = md.map(\.lastPathComponent).joined(separator: ", ")
        statusLines.insert("Processing: \(names)", at: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: ComposeResult
            do {
                result = try ComposeBridge.compose(markdownFiles: md)
            } catch {
                result = ComposeResult(
                    ok: false,
                    summary: "Compose failed",
                    detail: error.localizedDescription
                )
            }
            DispatchQueue.main.async {
                self.busy = false
                self.lastResult = result
                self.statusLines.insert(result.summary, at: 0)
                if self.statusLines.count > 12 {
                    self.statusLines = Array(self.statusLines.prefix(12))
                }
                AppDelegate.bringToForegroundRepeatedly()
                self.drainInbox()
            }
        }
    }
}
