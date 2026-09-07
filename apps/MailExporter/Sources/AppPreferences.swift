import Foundation
import Combine

enum StorageLocation: String, CaseIterable, Identifiable {
    case iCloud = "icloud"
    case local = "local"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iCloud: return "iCloud Drive (Recommended)"
        case .local: return "Local Mac (Application Support)"
        case .custom: return "Custom Folder"
        }
    }
}

/// App-wide preferences (Preferences menu / ⌘,).
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var debugMode: Bool {
        didSet {
            UserDefaults.standard.set(debugMode, forKey: Keys.debugMode)
        }
    }

    @Published var storageLocation: StorageLocation {
        didSet {
            UserDefaults.standard.set(storageLocation.rawValue, forKey: Keys.storageLocation)
        }
    }

    @Published var customStoragePath: String {
        didSet {
            UserDefaults.standard.set(customStoragePath, forKey: Keys.customStoragePath)
        }
    }

    @Published var autoCheckUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates)
        }
    }

    @Published var gitHubToken: String {
        didSet {
            UserDefaults.standard.set(gitHubToken, forKey: Keys.gitHubToken)
        }
    }

    private enum Keys {
        static let debugMode = "debugMode"
        static let storageLocation = "storageLocation"
        static let customStoragePath = "customStoragePath"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let gitHubToken = "gitHubToken"
    }

    private init() {
        debugMode = UserDefaults.standard.bool(forKey: Keys.debugMode)
        let rawLoc = UserDefaults.standard.string(forKey: Keys.storageLocation) ?? StorageLocation.iCloud.rawValue
        storageLocation = StorageLocation(rawValue: rawLoc) ?? .iCloud
        customStoragePath = UserDefaults.standard.string(forKey: Keys.customStoragePath) ?? ""
        if UserDefaults.standard.object(forKey: Keys.autoCheckUpdates) == nil {
            autoCheckUpdates = true
        } else {
            autoCheckUpdates = UserDefaults.standard.bool(forKey: Keys.autoCheckUpdates)
        }
        gitHubToken = UserDefaults.standard.string(forKey: Keys.gitHubToken) ?? ""
    }

    func reset() {
        debugMode = false
        storageLocation = .iCloud
        customStoragePath = ""
        autoCheckUpdates = true
        gitHubToken = ""
        UserDefaults.standard.removeObject(forKey: Keys.debugMode)
        UserDefaults.standard.removeObject(forKey: Keys.storageLocation)
        UserDefaults.standard.removeObject(forKey: Keys.customStoragePath)
        UserDefaults.standard.removeObject(forKey: Keys.autoCheckUpdates)
        UserDefaults.standard.removeObject(forKey: Keys.gitHubToken)
    }
}
