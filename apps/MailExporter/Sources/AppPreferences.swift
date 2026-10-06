import Foundation
import Combine

enum StorageLocation: String, CaseIterable, Identifiable {
    case iCloud = "icloud"
    case local = "local"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iCloud: return "iCloud"
        case .local: return "On this Mac"
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

    private enum Keys {
        static let debugMode = "debugMode"
        static let storageLocation = "storageLocation"
        static let customStoragePath = "customStoragePath"
    }

    private init() {
        debugMode = UserDefaults.standard.bool(forKey: Keys.debugMode)
        let rawLoc = UserDefaults.standard.string(forKey: Keys.storageLocation) ?? StorageLocation.iCloud.rawValue
        storageLocation = StorageLocation(rawValue: rawLoc) ?? .iCloud
        customStoragePath = UserDefaults.standard.string(forKey: Keys.customStoragePath) ?? ""
    }

    func reset() {
        debugMode = false
        storageLocation = .iCloud
        customStoragePath = ""
        UserDefaults.standard.removeObject(forKey: Keys.debugMode)
        UserDefaults.standard.removeObject(forKey: Keys.storageLocation)
        UserDefaults.standard.removeObject(forKey: Keys.customStoragePath)
        ScheduledExport.remove()
    }
}
