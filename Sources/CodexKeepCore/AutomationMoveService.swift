import Foundation

public enum AutomationMoveServiceError: LocalizedError, Equatable {
    case noSelectedAutomations
    case noTargetMachine
    case targetIsCurrentMachine
    case missingAutomation(String)
    case unableToMove(String)
    case unableToInstall(String)

    public var errorDescription: String? {
        switch self {
        case .noSelectedAutomations:
            "No automations were selected."
        case .noTargetMachine:
            "Choose a target machine."
        case .targetIsCurrentMachine:
            "Choose another machine."
        case let .missingAutomation(id):
            "Automation \(id) was not found."
        case let .unableToMove(message):
            "Could not move automations: \(message)"
        case let .unableToInstall(message):
            "Could not install moved automations: \(message)"
        }
    }
}

public struct AutomationSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var fileCount: Int
    public var byteCount: UInt64

    public init(id: String, path: String, fileCount: Int, byteCount: UInt64) {
        self.id = id
        self.path = path
        self.fileCount = fileCount
        self.byteCount = byteCount
    }
}

public struct AutomationMoveResult: Equatable, Sendable {
    public var movedCount: Int
    public var moveURL: URL
    public var safetySnapshotURL: URL
}

public struct AutomationMoveConsumeResult: Equatable, Sendable {
    public var installedCount: Int
    public var consumedMoveCount: Int
    public var safetySnapshotURL: URL?

    public static let empty = AutomationMoveConsumeResult(
        installedCount: 0,
        consumedMoveCount: 0,
        safetySnapshotURL: nil
    )
}

public struct AutomationMoveManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var sourceMachineName: String
    public var targetMachineName: String
    public var automations: [AutomationMoveManifestItem]

    public init(
        schemaVersion: Int = 1,
        createdAt: Date,
        sourceMachineName: String,
        targetMachineName: String,
        automations: [AutomationMoveManifestItem]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.sourceMachineName = sourceMachineName
        self.targetMachineName = targetMachineName
        self.automations = automations
    }
}

public struct AutomationMoveManifestItem: Codable, Equatable, Sendable {
    public var id: String
    public var fileCount: Int
    public var byteCount: UInt64

    public init(id: String, fileCount: Int, byteCount: UInt64) {
        self.id = id
        self.fileCount = fileCount
        self.byteCount = byteCount
    }
}

public final class AutomationMoveService {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func localAutomations(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [AutomationSummary] {
        let automationsURL = automationsURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: automationsURL.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: automationsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try contents
            .filter { url in
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    return false
                }

                return fileManager.fileExists(atPath: url.appendingPathComponent("automation.toml").path)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let stats = try statsForItem(at: url)
                return AutomationSummary(
                    id: url.lastPathComponent,
                    path: url.standardizedFileURL.path,
                    fileCount: stats.fileCount,
                    byteCount: stats.byteCount
                )
            }
    }

    public func moveAutomations(
        ids selectedIDs: Set<String>,
        to targetMachineName: String,
        settings: BackupSettings,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        moveID: String? = nil
    ) throws -> AutomationMoveResult {
        guard !selectedIDs.isEmpty else {
            throw AutomationMoveServiceError.noSelectedAutomations
        }

        guard !targetMachineName.isEmpty else {
            throw AutomationMoveServiceError.noTargetMachine
        }

        let currentMachineName = Machine.currentName()
        guard targetMachineName != currentMachineName else {
            throw AutomationMoveServiceError.targetIsCurrentMachine
        }

        let automationIDs = selectedIDs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let localRoot = automationsURL(homeDirectory: homeDirectory)
        let sourceURLs = try automationIDs.map { id in
            let sourceURL = localRoot.appendingPathComponent(id, isDirectory: true)
            guard fileManager.fileExists(atPath: sourceURL.appendingPathComponent("automation.toml").path) else {
                throw AutomationMoveServiceError.missingAutomation(id)
            }

            return sourceURL
        }

        do {
            let safetySnapshotURL = try createSafetySnapshot(
                for: sourceURLs,
                settings: settings,
                now: now
            )
            let moveURL = try createPendingMove(
                from: sourceURLs,
                to: targetMachineName,
                settings: settings,
                now: now,
                moveID: moveID
            )

            for sourceURL in sourceURLs {
                try fileManager.removeItem(at: sourceURL)
            }

            return AutomationMoveResult(
                movedCount: sourceURLs.count,
                moveURL: moveURL,
                safetySnapshotURL: safetySnapshotURL
            )
        } catch let error as AutomationMoveServiceError {
            throw error
        } catch {
            throw AutomationMoveServiceError.unableToMove(error.localizedDescription)
        }
    }

    public func consumePendingMoves(
        settings: BackupSettings,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) throws -> AutomationMoveConsumeResult {
        let pendingRoot = pendingMovesRoot(
            settings: settings,
            machineName: Machine.currentName()
        )

        guard fileManager.fileExists(atPath: pendingRoot.path) else {
            return .empty
        }

        let moveURLs = try fileManager.contentsOfDirectory(
            at: pendingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && !url.lastPathComponent.hasPrefix(".")
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !moveURLs.isEmpty else {
            return .empty
        }

        do {
            let manifests = moveURLs.compactMap { url -> (URL, AutomationMoveManifest)? in
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                guard let manifest = try? readMoveManifest(at: url) else {
                    return nil
                }

                return (url, manifest)
            }
            guard !manifests.isEmpty else {
                return .empty
            }

            let targetURLs = manifests.flatMap { moveURL, manifest in
                manifest.automations.map { item in
                    (
                        sourceURL: moveURL
                            .appendingPathComponent("Automations", isDirectory: true)
                            .appendingPathComponent(item.id, isDirectory: true),
                        targetURL: automationsURL(homeDirectory: homeDirectory)
                            .appendingPathComponent(item.id, isDirectory: true)
                    )
                }
            }
            let safetySnapshotURL = try createInstallSafetySnapshot(
                for: targetURLs.map(\.targetURL),
                settings: settings,
                now: now
            )

            var installedCount = 0
            for (sourceURL, targetURL) in targetURLs {
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    continue
                }

                try replaceItem(from: sourceURL, to: targetURL)
                installedCount += 1
            }

            for (moveURL, _) in manifests {
                try fileManager.removeItem(at: moveURL)
            }

            return AutomationMoveConsumeResult(
                installedCount: installedCount,
                consumedMoveCount: manifests.count,
                safetySnapshotURL: safetySnapshotURL
            )
        } catch let error as AutomationMoveServiceError {
            throw error
        } catch {
            throw AutomationMoveServiceError.unableToInstall(error.localizedDescription)
        }
    }

    private func createPendingMove(
        from sourceURLs: [URL],
        to targetMachineName: String,
        settings: BackupSettings,
        now: Date,
        moveID: String?
    ) throws -> URL {
        let currentMachineName = Machine.currentName()
        let root = pendingMovesRoot(settings: settings, machineName: targetMachineName)
        let id = moveID ?? "\(currentMachineName)-\(timestamp(for: now))-\(UUID().uuidString)"
        let finalURL = root.appendingPathComponent(id, isDirectory: true)
        let stagingURL = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        var manifestItems: [AutomationMoveManifestItem] = []
        let automationsURL = stagingURL.appendingPathComponent("Automations", isDirectory: true)
        try fileManager.createDirectory(at: automationsURL, withIntermediateDirectories: true)

        for sourceURL in sourceURLs {
            let destinationURL = automationsURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            try copyItem(from: sourceURL, to: destinationURL)
            let stats = try statsForItem(at: destinationURL)
            manifestItems.append(AutomationMoveManifestItem(
                id: sourceURL.lastPathComponent,
                fileCount: stats.fileCount,
                byteCount: stats.byteCount
            ))
        }

        let manifest = AutomationMoveManifest(
            createdAt: now,
            sourceMachineName: currentMachineName,
            targetMachineName: targetMachineName,
            automations: manifestItems
        )
        try encoder.encode(manifest)
            .write(to: stagingURL.appendingPathComponent("manifest.json"), options: .atomic)

        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: stagingURL, to: finalURL)
        return finalURL
    }

    private func createSafetySnapshot(
        for sourceURLs: [URL],
        settings: BackupSettings,
        now: Date
    ) throws -> URL {
        let snapshotURL = machineRoot(settings: settings, machineName: Machine.currentName())
            .appendingPathComponent("Automation Move Safety", isDirectory: true)
            .appendingPathComponent(timestamp(for: now), isDirectory: true)

        try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        let automationsURL = snapshotURL.appendingPathComponent("Codex", isDirectory: true)
            .appendingPathComponent("automations", isDirectory: true)
        try fileManager.createDirectory(at: automationsURL, withIntermediateDirectories: true)

        var manifestItems: [BackupManifestItem] = []
        for sourceURL in sourceURLs {
            let destinationURL = automationsURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            try copyItem(from: sourceURL, to: destinationURL)
            let stats = try statsForItem(at: destinationURL)
            manifestItems.append(BackupManifestItem(
                id: "codex-automations/\(sourceURL.lastPathComponent)",
                displayName: "Automation: \(sourceURL.lastPathComponent)",
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path,
                status: .copied,
                fileCount: stats.fileCount,
                byteCount: stats.byteCount,
                message: nil
            ))
        }

        let manifest = BackupManifest(
            appName: "Codex Keep Automation Move Safety",
            schemaVersion: 1,
            createdAt: now,
            machineName: Machine.currentName(),
            items: manifestItems,
            warnings: []
        )
        try encoder.encode(manifest)
            .write(to: snapshotURL.appendingPathComponent("manifest.json"), options: .atomic)

        return snapshotURL
    }

    private func createInstallSafetySnapshot(
        for targetURLs: [URL],
        settings: BackupSettings,
        now: Date
    ) throws -> URL? {
        let existingTargets = targetURLs.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingTargets.isEmpty else {
            return nil
        }

        return try createSafetySnapshot(
            for: existingTargets,
            settings: settings,
            now: now
        )
    }

    private func readMoveManifest(at moveURL: URL) throws -> AutomationMoveManifest {
        let manifestData = try Data(contentsOf: moveURL.appendingPathComponent("manifest.json"))
        let manifest = try decoder.decode(AutomationMoveManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else {
            throw AutomationMoveServiceError.unableToInstall("Unsupported automation move schema \(manifest.schemaVersion).")
        }

        guard manifest.targetMachineName == Machine.currentName() else {
            throw AutomationMoveServiceError.unableToInstall("Move target \(manifest.targetMachineName) does not match this Mac.")
        }

        return manifest
    }

    private func replaceItem(from sourceURL: URL, to targetURL: URL) throws {
        let targetParentURL = targetURL.deletingLastPathComponent()
        let stagingURL = targetParentURL.appendingPathComponent(".codex-keep-automation-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: targetParentURL, withIntermediateDirectories: true)
            try copyItem(from: sourceURL, to: stagingURL)
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.moveItem(at: stagingURL, to: targetURL)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    private func copyItem(from sourceURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func statsForItem(at url: URL) throws -> AutomationMoveCopyStats {
        guard fileManager.fileExists(atPath: url.path) else {
            return AutomationMoveCopyStats()
        }

        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue {
            return AutomationMoveCopyStats(fileCount: 1, byteCount: try byteCount(for: url))
        }

        var stats = AutomationMoveCopyStats()
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return stats
        }

        for case let childURL as URL in enumerator {
            let values = try childURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                continue
            }

            stats.fileCount += 1
            stats.byteCount += UInt64(values.fileSize ?? 0)
        }

        return stats
    }

    private func byteCount(for url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values.fileSize ?? 0)
    }

    private func pendingMovesRoot(settings: BackupSettings, machineName: String) -> URL {
        machineRoot(settings: settings, machineName: machineName)
            .appendingPathComponent("Automation Moves", isDirectory: true)
    }

    private func machineRoot(settings: BackupSettings, machineName: String) -> URL {
        URL(fileURLWithPath: settings.destinationRootPath)
            .standardizedFileURL
            .appendingPathComponent(machineName, isDirectory: true)
    }

    private func automationsURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("automations", isDirectory: true)
    }

    private func timestamp(for date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }
}

private extension AutomationMoveService {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

private struct AutomationMoveCopyStats: Equatable {
    var fileCount: Int = 0
    var byteCount: UInt64 = 0
}
