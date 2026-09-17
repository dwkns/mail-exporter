import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var store: JobsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StoragePreferencesView()
                    UpdatesPreferencesView()
                    AdvancedPreferencesView()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 560, height: 620)
        .background(HiddenWindowTitle())
    }
}

struct StoragePreferencesView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var store: JobsStore

    var body: some View {
        GroupedWell {
            SettingsSectionHeader(
                symbol: "externaldrive.fill",
                tint: .blue,
                title: "Storage",
                subtitle: "Where jobs.json lives"
            )

            GroupedWellDivider()

            ForEach(Array(StorageLocation.allCases.enumerated()), id: \.element.id) { index, loc in
                StorageChoiceRow(
                    location: loc,
                    selected: prefs.storageLocation == loc,
                    warning: loc == .iCloud && prefs.storageLocation == .iCloud && !JobsStore.isICloudAvailable
                        ? "iCloud is signed out or unavailable — using local Application Support until it is."
                        : nil
                ) {
                    store.switchLocation(to: loc)
                }

                if loc == .custom, prefs.storageLocation == .custom {
                    HStack(spacing: 8) {
                        TextField("Folder or file path", text: $prefs.customStoragePath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            chooseCustomFolder()
                        }
                    }
                    .padding(.leading, 54)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                }

                if index < StorageLocation.allCases.count - 1 {
                    GroupedWellDivider()
                }
            }

            GroupedWellDivider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc")
                            .font(.system(size: 11, weight: .medium))
                        Text("Active jobs.json")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                    Text(displayPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                HeaderActionButton(
                    title: "Reveal",
                    symbol: "folder.fill",
                    tint: .blue
                ) {
                    revealInFinder()
                }
                .help("Reveal jobs.json in Finder")
                .accessibilityLabel("Reveal in Finder")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 11)
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
        GroupedWell {
            HStack(alignment: .center, spacing: 12) {
                JobGlyph(symbol: "arrow.triangle.2.circlepath", tint: .indigo)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Updates")
                        .font(.system(size: 15, weight: .semibold))
                    Text("MailExporter \(updater.currentVersion) · build \(updater.currentBuild)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 11)

            GroupedWellDivider()

            SettingsToggleRow(
                title: "Check on launch",
                subtitle: "Look for a new version when MailExporter opens",
                isOn: $prefs.autoCheckUpdates
            )

            GroupedWellDivider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(updater.isChecking ? "Checking GitHub…" : "GitHub releases")
                        .font(.system(size: 15, weight: .semibold))
                    if let last = updater.lastCheckDate {
                        Text("Last checked \(Self.formatDate(last))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not checked yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                HeaderActionButton(
                    title: updater.isChecking ? "Checking…" : "Check Now",
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .indigo,
                    enabled: !updater.isChecking && !updater.isUpdating,
                    spinning: updater.isChecking
                ) {
                    updater.showUpdateWindow()
                }
                .help("Check GitHub for a newer MailExporter")
                .accessibilityLabel("Check for Updates Now")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 11)

            if updater.updateAvailable {
                GroupedWellDivider()
                updateAvailableRow
            } else if !updater.statusMessage.isEmpty {
                GroupedWellDivider()
                statusRow
            }
        }
    }

    private var updateAvailableRow: some View {
        HStack(alignment: .center, spacing: 12) {
            JobGlyph(symbol: "sparkles", tint: .orange, size: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("Version \(updater.latestVersion) is available")
                    .font(.system(size: 15, weight: .semibold))
                if !updater.releaseNotes.isEmpty {
                    Text(updater.releaseNotes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Button(action: {
                Task { await updater.downloadAndInstall() }
            }) {
                if updater.isUpdating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                } else {
                    Text("Install")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(updater.isUpdating)
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .background(Color.accentColor.opacity(0.08))
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if updater.errorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(updater.statusMessage)
                .foregroundStyle(updater.errorMessage != nil ? Color.red : Color.secondary)
                .lineLimit(2)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        GroupedWell {
            SettingsSectionHeader(
                symbol: "gearshape.2.fill",
                tint: .gray,
                title: "Advanced",
                subtitle: "Tools you rarely need"
            )

            GroupedWellDivider()

            SettingsToggleRow(
                title: "Debug Mode",
                subtitle: "Shows Clear Target on Export so you can wipe a folder and re-export from scratch.",
                isOn: $prefs.debugMode
            )

            GroupedWellDivider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Factory Reset")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Resets all settings back to defaults and deletes mailbox configurations from both this Mac and iCloud. Exported emails already saved in your folders will not be deleted.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                HeaderActionButton(
                    title: "Reset…",
                    symbol: "arrow.counterclockwise",
                    tint: .red
                ) {
                    showingResetAlert = true
                }
                .help("Reset MailExporter to factory settings")
                .accessibilityLabel("Reset to Factory Settings")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 11)
        }
        .alert("Reset MailExporter to Factory Settings?", isPresented: $showingResetAlert) {
            Button("Reset to Factory Settings", role: .destructive) {
                store.resetToFactorySettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all mailbox configurations and preferences from this Mac and iCloud.\n\nTip: You can export a backup of your settings anytime from File → Export Settings… before resetting.")
        }
    }
}

private struct SettingsSectionHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            JobGlyph(symbol: symbol, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.regular)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
    }
}

private struct StorageChoiceRow: View {
    let location: StorageLocation
    let selected: Bool
    var warning: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                JobGlyph(symbol: location.symbol, tint: location.tint, size: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 7) {
                        Text(location.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if warning != nil {
                            Text("Unavailable")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(warning ?? location.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(warning == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .accessibilityHidden(true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 11)
            .background(rowFill)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(location.title)
        .accessibilityValue(warning ?? location.subtitle)
        .accessibilityHint("Store jobs.json here")
    }

    private var rowFill: Color {
        hovering ? Color.primary.opacity(0.045) : .clear
    }
}

private extension StorageLocation {
    var title: String {
        switch self {
        case .iCloud: return "iCloud"
        case .local: return "This Mac"
        case .custom: return "Custom Folder"
        }
    }

    var subtitle: String {
        switch self {
        case .iCloud: return "App Sync — jobs follow this Mac’s iCloud"
        case .local: return "Application Support — stays on this computer"
        case .custom: return "Choose a folder or a jobs.json file"
        }
    }

    var symbol: String {
        switch self {
        case .iCloud: return "icloud.fill"
        case .local: return "desktopcomputer"
        case .custom: return "folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .iCloud: return .blue
        case .local: return .gray
        case .custom: return .orange
        }
    }
}
