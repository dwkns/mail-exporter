import AppKit
import Foundation
import SwiftUI

struct ReleaseInfo {
    var tag: String
    var name: String
    var body: String
    var assetName: String
    var assetDownloadURL: URL?
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published var isChecking: Bool = false
    @Published var isUpdating: Bool = false
    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var releaseTitle: String = ""
    @Published var releaseNotes: String = ""
    @Published var statusMessage: String = ""
    @Published var errorMessage: String? = nil
    @Published var lastCheckDate: Date? = nil

    private let repo = "dwkns/mail-exporter"
    private var activeRelease: ReleaseInfo?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }

    private init() {
        if AppPreferences.shared.autoCheckUpdates {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await checkForUpdates(silent: true)
            }
        }
    }

    static func compareVersions(latest: String, current: String) -> ComparisonResult {
        let cleanLatest = latest.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))
        let cleanCurrent = current.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))
        let v1 = cleanLatest.split(separator: ".").compactMap { Int($0) }
        let v2 = cleanCurrent.split(separator: ".").compactMap { Int($0) }
        let count = max(v1.count, v2.count)
        for i in 0..<count {
            let p1 = i < v1.count ? v1[i] : 0
            let p2 = i < v2.count ? v2[i] : 0
            if p1 > p2 { return .orderedDescending }
            if p1 < p2 { return .orderedAscending }
        }
        return .orderedSame
    }

    private func findGh() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
            NSHomeDirectory() + "/.homebrew/bin/gh",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        return nil
    }

    func checkForUpdates(silent: Bool = false) async {
        isChecking = true
        errorMessage = nil
        if !silent {
            statusMessage = "Checking GitHub for updates…"
        }

        do {
            let release = try await fetchLatestRelease()
            activeRelease = release
            lastCheckDate = Date()
            isChecking = false

            if let release = release, Self.compareVersions(latest: release.tag, current: currentVersion) == .orderedDescending {
                updateAvailable = true
                latestVersion = release.tag
                releaseTitle = release.name.isEmpty ? release.tag : release.name
                releaseNotes = release.body
                statusMessage = "New version \(release.tag) available!"
            } else {
                updateAvailable = false
                if !silent {
                    statusMessage = "MailExporter is up to date (v\(currentVersion))."
                }
            }
        } catch {
            isChecking = false
            if !silent {
                let msg = error.localizedDescription
                errorMessage = msg
                statusMessage = "Check failed: \(msg)"
            }
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo? {
        if let gh = findGh() {
            do {
                if let release = try await fetchViaGh(ghPath: gh) {
                    return release
                }
                return nil
            } catch {
                // If gh failed with an error, fall back to GitHub REST API
            }
        }
        return try await fetchViaAPI()
    }

    private func fetchViaGh(ghPath: String) async throws -> ReleaseInfo? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ghPath)
                proc.arguments = [
                    "release", "view",
                    "-R", self.repo,
                    "--json", "tagName,name,body,assets"
                ]
                let pipeOut = Pipe()
                let pipeErr = Pipe()
                proc.standardOutput = pipeOut
                proc.standardError = pipeErr

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus != 0 {
                        let errData = pipeErr.fileHandleForReading.readDataToEndOfFile()
                        let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                        if errStr.localizedCaseInsensitiveContains("release not found") || errStr.localizedCaseInsensitiveContains("no releases") {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(throwing: NSError(domain: "AppUpdater", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr]))
                        return
                    }
                    let outData = pipeOut.fileHandleForReading.readDataToEndOfFile()
                    guard let json = try JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
                        continuation.resume(throwing: NSError(domain: "AppUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid release response"]))
                        return
                    }

                    let tag = json["tagName"] as? String ?? ""
                    let name = json["name"] as? String ?? ""
                    let body = json["body"] as? String ?? ""
                    var assetName = ""
                    var assetURL: URL?

                    if let assets = json["assets"] as? [[String: Any]] {
                        for a in assets {
                            if let aName = a["name"] as? String, aName.hasSuffix(".zip") {
                                assetName = aName
                                if let urlStr = a["url"] as? String ?? a["browser_download_url"] as? String {
                                    assetURL = URL(string: urlStr)
                                }
                                break
                            }
                        }
                    }

                    continuation.resume(returning: ReleaseInfo(
                        tag: tag,
                        name: name,
                        body: body,
                        assetName: assetName,
                        assetDownloadURL: assetURL
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchViaAPI() async throws -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw NSError(domain: "AppUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"])
        }

        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MailExporter-App", forHTTPHeaderField: "User-Agent")

        let token = AppPreferences.shared.gitHubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? ""
        let effectiveToken = !token.isEmpty ? token : envToken
        if !effectiveToken.isEmpty {
            req.setValue("Bearer \(effectiveToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "AppUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey: "No response from GitHub"])
        }

        if http.statusCode == 404 {
            // No releases published yet on this repository
            return nil
        }
        guard http.statusCode == 200 else {
            throw NSError(domain: "AppUpdater", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub error (HTTP \(http.statusCode)). If this repository is private, authenticate with GitHub CLI (gh) or enter a Personal Access Token."])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AppUpdater", code: 3, userInfo: [NSLocalizedDescriptionKey: "Malformed GitHub release data"])
        }

        let tag = json["tag_name"] as? String ?? ""
        let name = json["name"] as? String ?? ""
        let body = json["body"] as? String ?? ""
        var assetName = ""
        var assetURL: URL?

        if let assets = json["assets"] as? [[String: Any]] {
            for a in assets {
                if let aName = a["name"] as? String, aName.hasSuffix(".zip") {
                    assetName = aName
                    if let urlStr = a["browser_download_url"] as? String {
                        assetURL = URL(string: urlStr)
                    }
                    break
                }
            }
        }

        return ReleaseInfo(
            tag: tag,
            name: name,
            body: body,
            assetName: assetName,
            assetDownloadURL: assetURL
        )
    }

    func downloadAndInstall() async {
        isUpdating = true
        errorMessage = nil
        statusMessage = "Downloading and applying update…"

        do {
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MailExporterUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            let zipPath = tmpDir.appendingPathComponent("MailExporter-macOS-arm64.zip")

            // Download
            if let gh = findGh() {
                let tag = activeRelease?.tag ?? latestVersion
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: gh)
                proc.arguments = [
                    "release", "download", tag,
                    "-R", self.repo,
                    "-p", "*.zip",
                    "-D", tmpDir.path,
                    "--clobber"
                ]
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    throw NSError(domain: "AppUpdater", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "gh release download failed"])
                }
            } else if let assetURL = activeRelease?.assetDownloadURL {
                var req = URLRequest(url: assetURL)
                req.setValue("MailExporter-App", forHTTPHeaderField: "User-Agent")
                let token = AppPreferences.shared.gitHubToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let (downloadedURL, _) = try await URLSession.shared.download(for: req)
                try FileManager.default.moveItem(at: downloadedURL, to: zipPath)
            } else {
                throw NSError(domain: "AppUpdater", code: 4, userInfo: [NSLocalizedDescriptionKey: "No download asset URL available."])
            }

            // Find the zip file in tmpDir
            let contents = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
            guard let downloadedZip = contents.first(where: { $0.hasSuffix(".zip") }) else {
                throw NSError(domain: "AppUpdater", code: 5, userInfo: [NSLocalizedDescriptionKey: "Download completed but zip file was not found."])
            }
            let finalZipURL = tmpDir.appendingPathComponent(downloadedZip)

            // Extract with ditto
            let extractDir = tmpDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", finalZipURL.path, extractDir.path]
            try ditto.run()
            ditto.waitUntilExit()

            // Find MailExporter.app in extractDir
            var foundAppURL: URL?
            if let enumerator = FileManager.default.enumerator(at: extractDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                while let item = enumerator.nextObject() as? URL {
                    if item.pathExtension == "app" {
                        foundAppURL = item
                        break
                    }
                }
            }

            guard let newAppURL = foundAppURL else {
                throw NSError(domain: "AppUpdater", code: 6, userInfo: [NSLocalizedDescriptionKey: "Extracted archive did not contain MailExporter.app."])
            }

            // Remove quarantine
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", newAppURL.path]
            try? xattr.run()
            xattr.waitUntilExit()

            // Current target app bundle to replace
            let targetBundlePath = Bundle.main.bundleURL.path

            statusMessage = "Relaunching into updated version…"

            // Execute detached script to replace running app and relaunch
            let script = """
            sleep 1
            rm -rf "\(targetBundlePath)"
            cp -R "\(newAppURL.path)" "\(targetBundlePath)"
            xattr -cr "\(targetBundlePath)"
            open "\(targetBundlePath)"
            """

            let replaceProc = Process()
            replaceProc.executableURL = URL(fileURLWithPath: "/bin/sh")
            replaceProc.arguments = ["-c", script]
            try replaceProc.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        } catch {
            isUpdating = false
            let msg = error.localizedDescription
            errorMessage = msg
            statusMessage = "Update failed: \(msg)"
        }
    }
}
