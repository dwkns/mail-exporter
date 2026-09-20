import Foundation
import Darwin

/// Reloads `jobs.json` when iCloud (or another Mac) writes it.
private final class JobsCloudPresenter: NSObject, NSFilePresenter {
    var presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    var onChange: (() -> Void)?

    override init() {
        let queue = OperationQueue()
        queue.name = "com.dwkns.MailExporter.jobs-presenter"
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidChange() {
        onChange?()
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
        onChange?()
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        onChange?()
        completionHandler(nil)
    }
}

/// Owns the iCloud presenter + directory watch so JobsStore deinit stays isolation-safe.
final class JobsCloudWatch {
    private var presenter: JobsCloudPresenter?
    private var watch: DispatchSourceFileSystemObject?

    func stop() {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenter = nil
        watch?.cancel()
        watch = nil
    }

    func start(url: URL, onChange: @escaping () -> Void) {
        stop()
        let presenter = JobsCloudPresenter()
        presenter.presentedItemURL = url
        presenter.onChange = onChange
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter

        let folder = url.deletingLastPathComponent()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler {
            onChange()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        watch = source
    }

    deinit {
        stop()
    }
}
