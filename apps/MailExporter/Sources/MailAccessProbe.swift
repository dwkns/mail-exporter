import AppKit
import ApplicationServices
import Foundation

enum PrivacySettingsPane: Equatable {
    case fullDiskAccess
    case accessibility
    case automation

    var buttonTitle: String {
        switch self {
        case .fullDiskAccess: return "Open Full Disk Access…"
        case .accessibility: return "Open Accessibility Settings…"
        case .automation: return "Open Automation Settings…"
        }
    }

    private var urlStrings: [String] {
        switch self {
        case .fullDiskAccess:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            ]
        case .accessibility:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            ]
        case .automation:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            ]
        }
    }

    func open() {
        for s in urlStrings {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}

enum MailAccessProbe {
    /// True when Mail library looks readable enough to export.
    static func canAccessMailLibrary() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mail = home.appendingPathComponent("Library/Mail")
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: mail,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return contents.contains { $0.lastPathComponent.hasPrefix("V") }
        } catch {
            return false
        }
    }

    /// True when Accessibility permission has been granted (for rich text paste).
    static func canAccessAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    static func looksLikeFullDiskDenial(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("full disk access")
            || lower.contains("operation not permitted")
            || lower.contains("permission denied")
            || lower.contains("blocked access to")
    }

    static func looksLikeAccessibilityDenial(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("accessibility")
            || lower.contains("assistive access")
            || lower.contains("not allowed assistive")
            || lower.contains("osascript is not allowed")
    }

    static func looksLikeAutomationDenial(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not authorized to send apple events")
            || lower.contains("not allowed to send apple events")
            || lower.contains("apple events")
            || (lower.contains("automation") && lower.contains("mail"))
            || lower.contains("(-1743)")
    }

    /// Prefer the most specific privacy pane for the error text.
    static func settingsPane(for message: String) -> PrivacySettingsPane? {
        if looksLikeAccessibilityDenial(message) {
            return .accessibility
        }
        if looksLikeAutomationDenial(message) {
            return .automation
        }
        if looksLikeFullDiskDenial(message) {
            return .fullDiskAccess
        }
        return nil
    }
}
