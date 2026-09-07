import SwiftUI

struct PermissionsBanner: View {
    @EnvironmentObject private var store: JobsStore
    @AppStorage("dismissedAccessibilityWarning") private var dismissedAccessibility: Bool = false

    var body: some View {
        if store.needsFullDiskAccess {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access Required")
                        .font(.subheadline.weight(.semibold))
                    Text("MailExporter needs Full Disk Access to read exported messages from ~/Library/Mail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open Settings…") {
                    PrivacySettingsPane.fullDiskAccess.open()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Check Again") {
                    store.refreshMailAccess()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(Divider(), alignment: .bottom)
        } else if store.needsAccessibility && !dismissedAccessibility {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility Permission Recommended")
                        .font(.subheadline.weight(.semibold))
                    Text("Needed to paste rich Markdown formatting into Apple Mail compose windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open Settings…") {
                    PrivacySettingsPane.accessibility.open()
                }
                .controlSize(.small)

                Button("Check Again") {
                    store.refreshMailAccess()
                }
                .controlSize(.small)

                Button("Dismiss") {
                    dismissedAccessibility = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.10))
            .overlay(Divider(), alignment: .bottom)
        }
    }
}
