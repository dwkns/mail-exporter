import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var store: JobsStore

    var body: some View {
        TabView {
            StoragePreferencesView()
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }
                .tag("storage")

            UpdatesPreferencesView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag("updates")

            AdvancedPreferencesView()
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                .tag("advanced")
        }
        .frame(width: 520, height: 320)
    }
}

struct StoragePreferencesView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var store: JobsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Store jobs in:")
                    .font(.subheadline.weight(.semibold))

                Picker("", selection: Binding(
                    get: { prefs.storageLocation },
                    set: { newLoc in
                        store.switchLocation(to: newLoc)
                    }
                )) {
                    ForEach(StorageLocation.allCases) { loc in
                        Text(loc.displayName).tag(loc)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if prefs.storageLocation == .custom {
                    HStack {
                        TextField("Folder or file path", text: $prefs.customStoragePath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            chooseCustomFolder()
                        }
                    }
                    .padding(.leading, 20)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Active jobs.json:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(store.configURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                Button("Reveal in Finder") {
                    revealInFinder()
                }

                if prefs.storageLocation == .iCloud && JobsStore.icloudDocsURL == nil {
                    Text("iCloud Drive not active on this Mac. Using local storage.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            store.switchLocation(to: .custom, customPath: path)
        }
    }

    private func revealInFinder() {
        let url = store.configURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) {
                NSWorkspace.shared.activateFileViewerSelecting([parent])
            } else {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([parent])
            }
        }
    }
}

struct UpdatesPreferencesView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MailExporter")
                        .font(.headline)
                    Text("Installed Version \(updater.currentVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Automatically check for updates on launch", isOn: $prefs.autoCheckUpdates)
                    .font(.subheadline)

                HStack(spacing: 12) {
                    Button(action: {
                        updater.showUpdateWindow()
                    }) {
                        if updater.isChecking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking GitHub…")
                        } else {
                            Text("Check for Updates Now")
                        }
                    }
                    .disabled(updater.isChecking || updater.isUpdating)

                    if let last = updater.lastCheckDate {
                        Text("Last checked: \(Self.formatDate(last))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if updater.updateAvailable {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.yellow)
                            Text("Version \(updater.latestVersion) is available!")
                                .font(.subheadline.weight(.semibold))
                        }

                        if !updater.releaseNotes.isEmpty {
                            Text(updater.releaseNotes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }

                        Button(action: {
                            Task { await updater.downloadAndInstall() }
                        }) {
                            if updater.isUpdating {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating…")
                            } else {
                                Text("Download and Install Update")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.isUpdating)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                } else if !updater.statusMessage.isEmpty {
                    HStack(spacing: 6) {
                        if updater.errorMessage != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text(updater.statusMessage)
                            .foregroundStyle(updater.errorMessage != nil ? .red : .primary)
                    }
                    .font(.caption)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

struct AdvancedPreferencesView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var store: JobsStore
    @State private var showingResetAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Debug Mode", isOn: $prefs.debugMode)
                    .font(.subheadline.weight(.semibold))

                Text("Shows Clear Target on Export so you can wipe a folder and re-export from scratch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Factory Reset")
                    .font(.subheadline.weight(.semibold))

                Text("Resets all settings back to defaults and deletes mailbox configurations from both this Mac and iCloud Drive. Exported emails already saved in your folders will not be deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Reset to Factory Settings…", role: .destructive) {
                    showingResetAlert = true
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Reset MailExporter to Factory Settings?", isPresented: $showingResetAlert) {
            Button("Reset to Factory Settings", role: .destructive) {
                store.resetToFactorySettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all mailbox configurations and preferences from this Mac and iCloud Drive.\n\nTip: You can export a backup of your settings anytime from File → Export Settings… before resetting.")
        }
    }
}
