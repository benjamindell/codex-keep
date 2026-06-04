import Foundation

public enum DeployServiceError: LocalizedError, Equatable {
    case missingManifest(String)
    case unsupportedManifestVersion(Int)
    case noSelectedItems
    case unableToCreateSafetySnapshot(String)
    case unableToDeploy(String)

    public var errorDescription: String? {
        switch self {
        case let .missingManifest(path):
            "No Codex Keep manifest was found at \(path)."
        case let .unsupportedManifestVersion(version):
            "Codex Keep cannot restore schema version \(version)."
        case .noSelectedItems:
            "No backup items were selected."
        case let .unableToCreateSafetySnapshot(message):
            "Could not create the safety snapshot: \(message)"
        case let .unableToDeploy(message):
            "Could not deploy the backup: \(message)"
        }
    }
}

public struct DeployPlan: Equatable, Sendable {
    public var sourceURL: URL
    public var manifest: BackupManifest
    public var items: [DeployPlanItem]
    public var warnings: [String]

    public var changedItemCount: Int {
        items.filter { $0.status == .changed || $0.status == .new }.count
    }

    public var unchangedItemCount: Int {
        items.filter { $0.status == .unchanged }.count
    }
}

public struct DeployPlanItem: Equatable, Identifiable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case new
        case changed
        case unchanged
        case missingFromBackup
    }

    public var id: String
    public var parentID: String?
    public var displayName: String
    public var sourceRelativePath: String
    public var targetPath: String
    public var status: Status
    public var fileCount: Int
    public var byteCount: UInt64

    public var isAutomation: Bool {
        parentID == "codex-automations"
    }
}

public struct DeployResult: Equatable, Sendable {
    public var deployedItemCount: Int
    public var safetySnapshotURL: URL
}

public final class DeployService {
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func makePlan(
        sourceURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        items: [BackupItem]? = nil
    ) throws -> DeployPlan {
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let manifestURL = standardizedSourceURL.appendingPathComponent("manifest.json")

        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw DeployServiceError.missingManifest(manifestURL.path)
        }

        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else {
            throw DeployServiceError.unsupportedManifestVersion(manifest.schemaVersion)
        }

        let restoreItems = items ?? DefaultBackupItems.items(homeDirectory: homeDirectory, fileManager: fileManager)
        let restoreItemsByID = Dictionary(uniqueKeysWithValues: restoreItems.map { ($0.id, $0) })
        let copiedManifestItems = manifest.items.filter { $0.status == .copied }
        var planItems: [DeployPlanItem] = []
        var warnings = manifest.warnings

        for manifestItem in copiedManifestItems {
            guard let backupItem = restoreItemsByID[manifestItem.id] else {
                warnings.append("\(manifestItem.displayName) is not recognized by this version of Codex Keep.")
                continue
            }

            if manifestItem.id == "codex-automations" {
                let automationItems = try automationPlanItems(
                    backupItem: backupItem,
                    sourceRootURL: standardizedSourceURL,
                    homeDirectory: homeDirectory
                )

                if automationItems.isEmpty {
                    planItems.append(try planItem(
                        id: backupItem.id,
                        parentID: nil,
                        displayName: backupItem.displayName,
                        sourceRelativePath: backupItem.destinationPath,
                        targetURL: URL(fileURLWithPath: backupItem.sourcePath),
                        sourceRootURL: standardizedSourceURL
                    ))
                } else {
                    planItems.append(contentsOf: automationItems)
                }
            } else {
                planItems.append(try planItem(
                    id: backupItem.id,
                    parentID: nil,
                    displayName: backupItem.displayName,
                    sourceRelativePath: backupItem.destinationPath,
                    targetURL: URL(fileURLWithPath: backupItem.sourcePath),
                    sourceRootURL: standardizedSourceURL
                ))
            }
        }

        return DeployPlan(
            sourceURL: standardizedSourceURL,
            manifest: manifest,
            items: planItems.sorted(by: sortPlanItems),
            warnings: warnings
        )
    }

    public func deploy(
        plan: DeployPlan,
        selectedItemIDs: Set<String>,
        settings: BackupSettings,
        now: Date = Date()
    ) throws -> DeployResult {
        let selectedItems = plan.items.filter { selectedItemIDs.contains($0.id) }
        guard !selectedItems.isEmpty else {
            throw DeployServiceError.noSelectedItems
        }

        let safetySnapshotURL: URL
        do {
            safetySnapshotURL = try createSafetySnapshot(
                for: selectedItems,
                settings: settings,
                now: now
            )
        } catch {
            throw DeployServiceError.unableToCreateSafetySnapshot(error.localizedDescription)
        }

        do {
            for item in selectedItems {
                let sourceURL = plan.sourceURL.appendingRelativePath(item.sourceRelativePath)
                let targetURL = URL(fileURLWithPath: item.targetPath)
                try replaceItem(from: sourceURL, to: targetURL)
            }
        } catch {
            throw DeployServiceError.unableToDeploy(error.localizedDescription)
        }

        return DeployResult(
            deployedItemCount: selectedItems.count,
            safetySnapshotURL: safetySnapshotURL
        )
    }

    private func automationPlanItems(
        backupItem: BackupItem,
        sourceRootURL: URL,
        homeDirectory: URL
    ) throws -> [DeployPlanItem] {
        let automationsURL = sourceRootURL.appendingRelativePath(backupItem.destinationPath)
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

                return fileManager.fileExists(
                    atPath: url.appendingPathComponent("automation.toml").path
                )
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let automationID = url.lastPathComponent
                return try planItem(
                    id: "\(backupItem.id)/\(automationID)",
                    parentID: backupItem.id,
                    displayName: "Automation: \(automationID)",
                    sourceRelativePath: "\(backupItem.destinationPath)/\(automationID)",
                    targetURL: homeDirectory
                        .appendingPathComponent(".codex", isDirectory: true)
                        .appendingPathComponent("automations", isDirectory: true)
                        .appendingPathComponent(automationID, isDirectory: true),
                    sourceRootURL: sourceRootURL
                )
            }
    }

    private func planItem(
        id: String,
        parentID: String?,
        displayName: String,
        sourceRelativePath: String,
        targetURL: URL,
        sourceRootURL: URL
    ) throws -> DeployPlanItem {
        let sourceURL = sourceRootURL.appendingRelativePath(sourceRelativePath)
        let stats = try statsForItem(at: sourceURL)
        let status: DeployPlanItem.Status

        if !fileManager.fileExists(atPath: sourceURL.path) {
            status = .missingFromBackup
        } else if !fileManager.fileExists(atPath: targetURL.path) {
            status = .new
        } else if try itemsMatch(sourceURL, targetURL) {
            status = .unchanged
        } else {
            status = .changed
        }

        return DeployPlanItem(
            id: id,
            parentID: parentID,
            displayName: displayName,
            sourceRelativePath: sourceRelativePath,
            targetPath: targetURL.standardizedFileURL.path,
            status: status,
            fileCount: stats.fileCount,
            byteCount: stats.byteCount
        )
    }

    private func createSafetySnapshot(
        for items: [DeployPlanItem],
        settings: BackupSettings,
        now: Date
    ) throws -> URL {
        let machineRoot = URL(fileURLWithPath: settings.destinationRootPath)
            .standardizedFileURL
            .appendingPathComponent(Machine.currentName(), isDirectory: true)
        let safetySnapshotURL = machineRoot
            .appendingPathComponent("Restore Safety", isDirectory: true)
            .appendingPathComponent(safetySnapshotFolderName(for: now), isDirectory: true)

        try fileManager.createDirectory(at: safetySnapshotURL, withIntermediateDirectories: true)

        var snapshotItems: [BackupManifestItem] = []
        for item in items {
            let sourceURL = URL(fileURLWithPath: item.targetPath).standardizedFileURL
            let destinationURL = safetySnapshotURL.appendingRelativePath(safetyRelativePath(for: sourceURL))

            guard fileManager.fileExists(atPath: sourceURL.path) else {
                snapshotItems.append(BackupManifestItem(
                    id: item.id,
                    displayName: item.displayName,
                    sourcePath: sourceURL.path,
                    destinationPath: destinationURL.path,
                    status: .missing,
                    fileCount: 0,
                    byteCount: 0,
                    message: "No local item existed before deploy."
                ))
                continue
            }

            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try copyItem(from: sourceURL, to: destinationURL)
            let stats = try statsForItem(at: destinationURL)
            snapshotItems.append(BackupManifestItem(
                id: item.id,
                displayName: item.displayName,
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path,
                status: .copied,
                fileCount: stats.fileCount,
                byteCount: stats.byteCount,
                message: nil
            ))
        }

        let manifest = BackupManifest(
            appName: "Codex Keep Restore Safety",
            schemaVersion: 1,
            createdAt: now,
            machineName: Machine.currentName(),
            items: snapshotItems,
            warnings: []
        )
        try encoder.encode(manifest)
            .write(to: safetySnapshotURL.appendingPathComponent("manifest.json"), options: .atomic)

        return safetySnapshotURL
    }

    private func replaceItem(from sourceURL: URL, to targetURL: URL) throws {
        let targetParentURL = targetURL.deletingLastPathComponent()
        let stagingURL = targetParentURL.appendingPathComponent(".codex-keep-deploy-\(UUID().uuidString)")

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

    private func copyItem(from sourceURL: URL, to targetURL: URL) throws {
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.copyItem(at: sourceURL, to: targetURL)
    }

    private func itemsMatch(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        var firstIsDirectory: ObjCBool = false
        var secondIsDirectory: ObjCBool = false
        let firstExists = fileManager.fileExists(atPath: firstURL.path, isDirectory: &firstIsDirectory)
        let secondExists = fileManager.fileExists(atPath: secondURL.path, isDirectory: &secondIsDirectory)

        guard firstExists && secondExists else {
            return firstExists == secondExists
        }

        guard firstIsDirectory.boolValue == secondIsDirectory.boolValue else {
            return false
        }

        if firstIsDirectory.boolValue {
            let firstFiles = try regularFilePaths(in: firstURL)
            let secondFiles = try regularFilePaths(in: secondURL)
            guard firstFiles == secondFiles else {
                return false
            }

            for relativePath in firstFiles {
                let firstChild = firstURL.appendingRelativePath(relativePath)
                let secondChild = secondURL.appendingRelativePath(relativePath)
                if try Data(contentsOf: firstChild) != Data(contentsOf: secondChild) {
                    return false
                }
            }

            return true
        }

        return try Data(contentsOf: firstURL) == Data(contentsOf: secondURL)
    }

    private func regularFilePaths(in directoryURL: URL) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        let rootPath = directoryURL.standardizedFileURL.path
        var paths: Set<String> = []
        for case let childURL as URL in enumerator {
            let values = try childURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            let childPath = childURL.standardizedFileURL.path
            guard childPath.hasPrefix(rootPath + "/") else {
                continue
            }

            paths.insert(String(childPath.dropFirst(rootPath.count + 1)))
        }

        return paths
    }

    private func statsForItem(at url: URL) throws -> CopyStats {
        guard fileManager.fileExists(atPath: url.path) else {
            return CopyStats()
        }

        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if !isDirectory.boolValue {
            return CopyStats(fileCount: 1, byteCount: try byteCount(for: url))
        }

        var stats = CopyStats()
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
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

    private func safetyRelativePath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path

        if path == homePath {
            return "Home"
        }

        if path.hasPrefix(homePath + "/") {
            return "Home/" + String(path.dropFirst(homePath.count + 1))
        }

        return "Absolute/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func safetySnapshotFolderName(for date: Date) -> String {
        Self.safetySnapshotDateFormatter.string(from: date)
    }

    private func sortPlanItems(_ first: DeployPlanItem, _ second: DeployPlanItem) -> Bool {
        if first.isAutomation != second.isAutomation {
            return first.isAutomation && !second.isAutomation
        }

        return first.displayName.localizedStandardCompare(second.displayName) == .orderedAscending
    }
}

private extension DeployService {
    static let safetySnapshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

private extension URL {
    func appendingRelativePath(_ relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }
}

private struct CopyStats: Equatable {
    var fileCount: Int = 0
    var byteCount: UInt64 = 0
}
