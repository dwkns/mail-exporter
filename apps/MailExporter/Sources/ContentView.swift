import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: JobsStore
    @ObservedObject private var inbox = ComposeInbox.shared

    var body: some View {
        VStack(spacing: 0) {
            PermissionsBanner()
            RunView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            AppDelegate.focusMainWindow()
            store.refreshMailAccess()
            drainPendingDrafts()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshMailAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mailExporterPermissionsChanged)) { _ in
            store.refreshMailAccess()
        }
        .onChange(of: inbox.generation) { _ in drainPendingDrafts() }
        .onOpenURL { url in
            if url.scheme?.lowercased() == "mailexporter" {
                MailExporterURL.handle(url)
                return
            }
            ComposeInbox.shared.enqueue([url])
        }
    }

    private func drainPendingDrafts() {
        // Drain without forcing MailExporter front — MakeMailDraft activates Mail,
        // and bringing this window forward afterward covers the new draft.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            ComposeRunner.shared.drainInbox()
        }
    }
}
