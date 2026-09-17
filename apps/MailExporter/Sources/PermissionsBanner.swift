import SwiftUI

struct PermissionsBanner: View {
    @EnvironmentObject private var store: JobsStore
    @AppStorage("dismissedFullDiskWarning") private var dismissedFullDisk: Bool = false
    @AppStorage("dismissedAccessibilityWarning") private var dismissedAccessibility: Bool = false
    @AppStorage("dismissedAutomationWarning") private var dismissedAutomation: Bool = false

    var body: some View {
        if store.needsFullDiskAccess && !dismissedFullDisk {
            banner(
                icon: "lock.shield.fill",
                tint: .orange,
                title: "Full Disk Access Required",
                detail: "Grant Full Disk Access to MailExporter (this app). If you run exports from Cursor or Claude Desktop instead, grant those apps. Terminal needs it for `python3 -m engine`. If the toggle is already on but this banner stays, remove MailExporter (−), add it again (+), then quit and reopen.",
                settings: .fullDiskAccess,
                onDismiss: { dismissedFullDisk = true }
            )
        } else if store.needsAutomation && !dismissedAutomation {
            banner(
                icon: "gearshape.2.fill",
                tint: .orange,
                title: "Automation → Mail Required",
                detail: "The first draft can fail with −1743 until MailExporter is allowed to control Mail. System Settings → Privacy & Security → Automation → MailExporter → Mail.",
                settings: .automation,
                onDismiss: { dismissedAutomation = true }
            )
        } else if store.needsAccessibility && !dismissedAccessibility {
            banner(
                icon: "hand.raised.fill",
                tint: .blue,
                title: "Accessibility Permission Recommended",
                detail: "Needed to paste rich Markdown formatting into Apple Mail. Safe to dismiss if you only need plain-text drafts.",
                settings: .accessibility,
                onDismiss: { dismissedAccessibility = true }
            )
        }
    }

    @ViewBuilder
    private func banner(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        settings: PrivacySettingsPane,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button(action: { settings.open() }) {
                    Label("Open Settings…", systemImage: "gearshape")
                        .labelStyle(.trailingIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Check Again") {
                    // Re-show if the user dismissed earlier and is re-checking.
                    if settings == .fullDiskAccess { dismissedFullDisk = false }
                    if settings == .accessibility { dismissedAccessibility = false }
                    if settings == .automation { dismissedAutomation = false }
                    store.refreshMailAccess()
                }
                .controlSize(.small)

                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .overlay(Divider(), alignment: .bottom)
    }
}
