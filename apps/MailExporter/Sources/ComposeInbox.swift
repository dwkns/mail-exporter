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

/// One drop, Choose Files pick, or MCP compose.
struct DropBatch: Identifiable, Equatable {
    let id: UUID
    var files: [DroppedFileRecord]
    var outcomes: [ComposeFileOutcome]

    init(files: [DroppedFileRecord]) {
        self.id = UUID()
        self.files = files
        self.outcomes = []
    }
}

/// Queues Markdown files opened via Dock/Finder drop onto the app icon
/// (or `open -a`), so the Export pane drop zone can compose them.
final class ComposeInbox: ObservableObject {
    static let shared = ComposeInbox()

    @Published private(set) var pendingBatches: [(id: UUID, urls: [URL])] = []
    /// Bumped so the drop zone re-processes even if the same paths are dropped again.
    @Published private(set) var generation: UInt = 0
    /// The drop the zone is showing now. Nil is the empty hint.
    @Published private(set) var currentBatch: DropBatch?
    /// Older drops, newest first. The zone keeps these behind a collapsed control.
    @Published private(set) var earlierBatches: [DropBatch] = []

    private let earlierLimit = 20

    private init() {}

    func enqueue(_ urls: [URL]) {
        let md = Self.markdownURLs(from: urls)
        guard !md.isEmpty else { return }
        let apply = {
            let batchId = self.beginBatch(md)
            self.pendingBatches.append((id: batchId, urls: md))
            self.generation &+= 1
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Show these files as the current drop. The previous drop moves into earlier history.
    @discardableResult
    func beginBatch(_ urls: [URL]) -> UUID {
        let md = Self.markdownURLs(from: urls)
        let now = Date()
        let records = md.map { DroppedFileRecord(url: $0, droppedAt: now) }
        if let current = currentBatch {
            pushEarlier(current)
        }
        let batch = DropBatch(files: records)
        currentBatch = batch
        return batch.id
    }

    /// Remove the current drop from the zone and return the empty hint.
    func clearCurrentDisplay() {
        if let current = currentBatch {
            pushEarlier(current)
        }
        currentBatch = nil
    }

    func apply(batchId: UUID, outcomes: [ComposeFileOutcome]) {
        let write = {
            if self.currentBatch?.id == batchId {
                self.currentBatch?.outcomes = outcomes
                return
            }
            if let index = self.earlierBatches.firstIndex(where: { $0.id == batchId }) {
                self.earlierBatches[index].outcomes = outcomes
            }
        }
        if Thread.isMainThread {
            write()
        } else {
            DispatchQueue.main.async(execute: write)
        }
    }

    func addPending(id: UUID, urls: [URL]) {
        pendingBatches.append((id: id, urls: urls))
        generation &+= 1
    }

    func takePending() -> (id: UUID, urls: [URL])? {
        guard !pendingBatches.isEmpty else { return nil }
        return pendingBatches.removeFirst()
    }

    var hasPending: Bool { !pendingBatches.isEmpty }

    private func pushEarlier(_ batch: DropBatch) {
        earlierBatches.insert(batch, at: 0)
        if earlierBatches.count > earlierLimit {
            earlierBatches = Array(earlierBatches.prefix(earlierLimit))
        }
    }

    private static func markdownURLs(from urls: [URL]) -> [URL] {
        urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "md" || ext == "markdown" || ext == "txt"
        }
    }
}

/// Always-on composer so Dock/Finder drops work even before the Export pane is visible.
final class ComposeRunner: ObservableObject {
    static let shared = ComposeRunner()

    @Published var busy = false
    @Published var lastResult: ComposeResult?
    /// Bumps each time a compose result is stored, including a repeat of the same failure.
    @Published private(set) var resultGeneration: UInt = 0
    @Published var statusLines: [String] = []

    private init() {}

    func drainInbox() {
        if busy { return }
        let inbox = ComposeInbox.shared
        guard let pending = inbox.takePending() else { return }
        process(urls: pending.urls, batchId: pending.id)
    }

    /// Store a result that did not go through ``process`` (MCP compose).
    func noteExternal(_ result: ComposeResult) {
        lastResult = result
        resultGeneration &+= 1
    }

    func process(urls: [URL], batchId: UUID? = nil) {
        let md = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "md" || ext == "markdown" || ext == "txt"
        }
        guard !md.isEmpty else { return }
        let inbox = ComposeInbox.shared
        let id = batchId ?? inbox.beginBatch(md)
        if busy {
            inbox.addPending(id: id, urls: md)
            return
        }
        busy = true
        let names = md.map(\.lastPathComponent).joined(separator: ", ")
        statusLines.insert("Processing: \(names)", at: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: ComposeResult
            do {
                result = try ComposeBridge.compose(markdownFiles: md)
            } catch {
                let detail = error.localizedDescription
                let files = md.map {
                    ComposeFileOutcome(name: $0.lastPathComponent, ok: false, detail: detail)
                }
                result = ComposeResult(
                    ok: false,
                    summary: "Compose failed",
                    detail: detail,
                    files: files
                )
            }
            DispatchQueue.main.async {
                self.busy = false
                inbox.apply(batchId: id, outcomes: result.files)
                self.lastResult = result
                self.resultGeneration &+= 1
                DraftNotifier.announce(result, draftCount: md.count)
                self.statusLines.insert(result.summary, at: 0)
                if self.statusLines.count > 12 {
                    self.statusLines = Array(self.statusLines.prefix(12))
                }
                let blob = result.summary + "\n" + result.detail
                if MailAccessProbe.looksLikeAutomationDenial(blob) {
                    UserDefaults.standard.set(true, forKey: "mailExporterNeedsAutomation")
                    UserDefaults.standard.set(false, forKey: "dismissedAutomationWarning")
                    NotificationCenter.default.post(name: .mailExporterPermissionsChanged, object: nil)
                } else if result.ok {
                    UserDefaults.standard.set(false, forKey: "mailExporterNeedsAutomation")
                }
                self.drainInbox()
            }
        }
    }
}
