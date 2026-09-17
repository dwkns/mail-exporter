import AppKit
import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            StoragePreferencesView()
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }

            UpdatesPreferencesView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }

            AdvancedPreferencesView()
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
        }
        .frame(width: 520, height: 440)
        .background(HiddenWindowTitle())
    }
}

private struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StoragePreferencesView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var store: JobsStore

    var body: some View {
        SettingsPane {
            Text("Store jobs in")
                .font(.subheadline.weight(.semibold))

            Picker("", selection: Binding(
                get: { prefs.storageLocation },
                set: { store.switchLocation(to: $0) }
            )) {
                ForEach(StorageLocation.allCases) { loc in
                    Text(loc.displayName).tag(loc)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if prefs.storageLocation == .custom {
                HStack(spacing: 8) {
                    TextField("Folder or file path", text: $prefs.customStoragePath)
                        .textFieldStyle(.roundedBorder)
                    Button(action: chooseCustomFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.trailingIcon)
                    }
                }
                .padding(.leading, 20)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Active jobs.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(displayPath)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }

            storageStatusCopy

            HStack(alignment: .center, spacing: 12) {
                Button(action: revealInFinder) {
                    Label("Reveal in Finder", systemImage: "folder")
                        .labelStyle(.trailingIcon)
                }
            }
        }
    }

    @ViewBuilder
    private var storageStatusCopy: some View {
        switch prefs.storageLocation {
        case .iCloud:
            if JobsStore.isICloudAvailable {
                Text("Jobs sync through the private iCloud container on this Apple ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("iCloud is signed out or this build has no iCloud entitlement. Jobs are stored on this Mac until the container is available.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .local:
            Text("Jobs stay on this Mac (Application Support). They do not sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .custom:
            Text("Jobs are stored in the folder you chose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayPath: String {
        let home = NSHomeDirectory()
        let expanded = store.configURL.path
        if expanded.hasPrefix(home) {
            return "~" + expanded.dropFirst(home.count)
        }
        return expanded
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            store.switchLocation(to: .custom, customPath: url.path)
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
        SettingsPane {
            VStack(alignment: .leading, spacing: 2) {
                Text("MailExporter")
                    .font(.subheadline.weight(.semibold))
                Text("Version \(updater.currentVersion) (build \(updater.currentBuild))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Automatically check for updates on launch", isOn: $prefs.autoCheckUpdates)

            HStack(spacing: 12) {
                Button {
                    updater.showUpdateWindow()
                } label: {
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
                    Text("Last checked \(Self.formatDate(last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if updater.updateAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Version \(updater.latestVersion) is available")
                        .font(.subheadline.weight(.semibold))
                    if !updater.releaseNotes.isEmpty {
                        Text(updater.releaseNotes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Button {
                        Task { await updater.downloadAndInstall() }
                    } label: {
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
            } else if !updater.statusMessage.isEmpty {
                HStack(spacing: 6) {
                    if updater.errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(updater.statusMessage)
                        .foregroundStyle(updater.errorMessage != nil ? Color.red : Color.secondary)
                }
                .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub token (optional)")
                    .font(.subheadline.weight(.semibold))
                SecureField("Personal access token", text: $prefs.gitHubToken)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in Keychain. Only needed if GitHub rate-limits Check for Updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
    @State private var mcpStatus = ""

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Debug Mode", isOn: $prefs.debugMode)

                Text("Shows Clear Target on Export so you can wipe a folder and re-export from scratch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Cursor MCP")
                    .font(.subheadline.weight(.semibold))
                Text("Write the installed helper into ~/.cursor/mcp.json so Cursor can list jobs and read export folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install mail-exporter MCP for Cursor") {
                    mcpStatus = MCPInstall.installCursor()
                }
                Button("Install mail-exporter MCP for Claude Desktop") {
                    mcpStatus = MCPInstall.installClaude()
                }
                Button("Install MailExporter skill") {
                    mcpStatus = MCPInstall.installSkill()
                }
                if !mcpStatus.isEmpty {
                    Text(mcpStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Export All every hour", isOn: $prefs.scheduledExportEnabled)
                Text("Uses a user launchd job that opens mailexporter://export-all. Folders go stale unless something runs ⌘E.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Factory Reset")
                    .font(.subheadline.weight(.semibold))

                Text("Resets settings and deletes jobs.json from this Mac and iCloud. Export folders on disk are left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Reset to Factory Settings…", role: .destructive) {
                    showingResetAlert = true
                }
            }
        }
        .alert("Reset MailExporter to Factory Settings?", isPresented: $showingResetAlert) {
            Button("Reset to Factory Settings", role: .destructive) {
                store.resetToFactorySettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove jobs.json and preferences from this Mac and iCloud.\n\nExport folders stay on disk. You can export a backup from File → Export Settings… first.")
        }
    }
}
