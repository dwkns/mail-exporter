import AppKit
import SwiftUI

enum AppTab: Hashable {
    case export
    case send
    case mailboxes
}

struct ContentView: View {
    @EnvironmentObject private var store: JobsStore
    @ObservedObject private var inbox = ComposeInbox.shared
    @State private var selectedTab: AppTab = .export

    var body: some View {
        VStack(spacing: 0) {
            PermissionsBanner()

            TabView(selection: $selectedTab) {
                RunView(onEditMailbox: { jobID in
                    store.selectedID = jobID
                    selectedTab = .mailboxes
                })
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                .tag(AppTab.export)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                SendView()
                    .tabItem { Label("Send Messages", systemImage: "envelope") }
                    .tag(AppTab.send)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ConfigView(isActive: selectedTab == .mailboxes)
                    .tabItem { Label("Mailboxes", systemImage: "tray.full") }
                    .tag(AppTab.mailboxes)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            AppDelegate.focusMainWindow()
            store.refreshMailAccess()
            openSendAndCompose()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshMailAccess()
        }
        .onChange(of: inbox.generation) { _ in openSendAndCompose() }
        .onChange(of: inbox.wantsSendTab) { wants in
            if wants { openSendAndCompose() }
        }
        .onOpenURL { url in
            ComposeInbox.shared.enqueue([url])
        }
    }

    private func openSendAndCompose() {
        if inbox.hasPending || inbox.wantsSendTab {
            selectedTab = .send
            inbox.wantsSendTab = false
        }
        // Let the window come forward before osascript activates Mail.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AppDelegate.focusMainWindow()
            ComposeRunner.shared.drainInbox()
        }
    }
}
