import CryptoKit
import Foundation

public enum BackupServiceError: LocalizedError, Equatable {
    case destinationInsideSource(source: String, destination: String)
    case unableToPublishBackup(String)

    public var errorDescription: String? {
        switch self {
        case let .destinationInsideSource(source, destination):
            "Backup destination \(destination) cannot be inside source \(source)."
        case let .unableToPublishBackup(message):
            "Could not publish the backup: \(message)"
        }
    }
}

public final class BackupService {
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func runBackup(
        settings: BackupSettings,
        items: [BackupItem] = DefaultBackupItems.items(),
        now: Date = Date()
    ) throws -> BackupResult {
        let machineName = Machine.currentName()
        let machineRoot = URL(fileURLWithPath: settings.destinationRootPath)
            .standardizedFileURL
            .appendingPathComponent(machineName, isDirectory: true)
        let latestURL = machineRoot.appendingPathComponent("latest", isDirectory: true)
        let snapshotsURL = machineRoot.appendingPathComponent("Snapshots", isDirectory: true)
        let stagingURL = machineRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: machineRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        var manifestItems: [BackupManifestItem] = []
        var manifestFiles: [BackupManifestFile] = []
        var warnings: [String] = []

        for item in items where settings.isEnabled(item) {
            let sourceURL = URL(fileURLWithPath: item.sourcePath).standardizedFileURL
            let destinationURL = stagingURL.appendingRelativePath(item.destinationPath)

            do {
                try validateDestination(destinationURL, isNotInside: sourceURL)

                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    let warning = "\(item.displayName) was not found at \(sourceURL.path)."
                    if item.required {
                        warnings.append(warning)
                    }

                    manifestItems.append(BackupManifestItem(
                        id: item.id,
                        displayName: item.displayName,
                        sourcePath: sourceURL.path,
                        destinationPath: destinationURL.path,
                        status: .missing,
                        fileCount: 0,
                        byteCount: 0,
                        message: warning
                    ))
                    continue
                }

                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let stats = try copyItem(from: sourceURL, to: destinationURL, item: item)
                manifestFiles.append(contentsOf: try fileRecords(
                    for: item,
                    sourceURL: sourceURL,
                    backupURL: destinationURL
                ))

                manifestItems.append(BackupManifestItem(
                    id: item.id,
                    displayName: item.displayName,
                    sourcePath: sourceURL.path,
                    destinationPath: destinationURL.path,
                    status: .copied,
                    fileCount: stats.fileCount,
                    byteCount: stats.byteCount,
                    message: nil
                ))
            } catch {
                warnings.append("\(item.displayName) failed: \(error.localizedDescription)")
                manifestItems.append(BackupManifestItem(
                    id: item.id,
                    displayName: item.displayName,
                    sourcePath: item.sourcePath,
                    destinationPath: destinationURL.path,
                    status: .failed,
                    fileCount: 0,
                    byteCount: 0,
                    message: error.localizedDescription
                ))
            }
        }

        let manifest = BackupManifest(
            appName: "Codex Keep",
            schemaVersion: 1,
            createdAt: now,
            machineName: machineName,
            items: manifestItems,
            files: manifestFiles.sorted { first, second in
                first.backupRelativePath.localizedStandardCompare(second.backupRelativePath) == .orderedAscending
            },
            tombstones: manifestTombstones(from: settings, copiedFiles: manifestFiles),
            warnings: warnings
        )

        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stagingURL.appendingPathComponent("manifest.json"), options: .atomic)
        try publishPayloadArchive(from: stagingURL, machineRoot: machineRoot)
        try publishBackupContents(to: latestURL, from: stagingURL)
        try publishDailySnapshot(in: snapshotsURL, from: stagingURL, now: now)
        try pruneDailySnapshots(in: snapshotsURL, keeping: 7)
        try removeManagedDuplicateFolders(in: machineRoot, baseNames: ["latest", "Snapshots"])
        try removeManagedDuplicateFolders(in: latestURL, baseNames: managedTopLevelFolderNames(for: items, settings: settings))
        try removeDuplicateSnapshotFolders(in: snapshotsURL)
        try fileManager.removeItem(at: stagingURL)

        return BackupResult(manifest: manifest, latestURL: latestURL)
    }

    private func publishPayloadArchive(from stagingURL: URL, machineRoot: URL) throws {
        let temporaryArchiveURL = machineRoot.appendingPathComponent(".payload-\(UUID().uuidString).zip")
        defer {
            if fileManager.fileExists(atPath: temporaryArchiveURL.path) {
                try? fileManager.removeItem(at: temporaryArchiveURL)
            }
        }

        try PayloadArchive.create(contentsOf: stagingURL, archiveURL: temporaryArchiveURL)
        try fileManager.copyItem(
            at: temporaryArchiveURL,
            to: stagingURL.appendingPathComponent(PayloadArchive.fileName)
        )
    }

    private func validateDestination(_ destinationURL: URL, isNotInside sourceURL: URL) throws {
        let source = sourceURL.standardizedFileURL.path
        let destination = destinationURL.standardizedFileURL.path

        if destination == source || destination.hasPrefix(source + "/") {
            throw BackupServiceError.destinationInsideSource(source: source, destination: destination)
        }
    }

    private func publishBackupContents(to destinationURL: URL, from stagingURL: URL) throws {
        let temporaryDestinationURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent)-publish-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(at: temporaryDestinationURL, withIntermediateDirectories: true)
            try copyContents(from: stagingURL, to: temporaryDestinationURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryDestinationURL, to: destinationURL)
        } catch {
            if fileManager.fileExists(atPath: temporaryDestinationURL.path) {
                try? fileManager.removeItem(at: temporaryDestinationURL)
            }
            throw BackupServiceError.unableToPublishBackup(error.localizedDescription)
        }
    }

    private func publishDailySnapshot(in snapshotsURL: URL, from stagingURL: URL, now: Date) throws {
        let snapshotURL = snapshotsURL.appendingPathComponent(snapshotFolderName(for: now), isDirectory: true)
        try publishBackupContents(to: snapshotURL, from: stagingURL)
    }

    private func pruneDailySnapshots(in snapshotsURL: URL, keeping retentionCount: Int) throws {
        guard fileManager.fileExists(atPath: snapshotsURL.path) else {
            return
        }

        let snapshots = try fileManager.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        .filter { snapshotDate(from: $0.lastPathComponent) != nil }
        .sorted { first, second in
            snapshotDate(from: first.lastPathComponent)! > snapshotDate(from: second.lastPathComponent)!
        }

        for snapshot in snapshots.dropFirst(retentionCount) {
            try fileManager.removeItem(at: snapshot)
        }
    }

    private func removeContents(of directoryURL: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )

        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }

    private func copyContents(from sourceDirectoryURL: URL, to destinationDirectoryURL: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: sourceDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )

        for sourceURL in contents {
            let destinationURL = destinationDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private func removeManagedDuplicateFolders(in directoryURL: URL, baseNames: Set<String>) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }

        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for url in contents where baseNames.contains(numberedDuplicateBaseName(for: url) ?? "") {
            try fileManager.removeItem(at: url)
        }
    }

    private func removeDuplicateSnapshotFolders(in snapshotsURL: URL) throws {
        guard fileManager.fileExists(atPath: snapshotsURL.path) else {
            return
        }

        let snapshotNames = try fileManager.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        .map(\.lastPathComponent)
        .filter { snapshotDate(from: $0) != nil }

        try removeManagedDuplicateFolders(in: snapshotsURL, baseNames: Set(snapshotNames))
    }

    private func numberedDuplicateBaseName(for url: URL) -> String? {
        let parts = url.lastPathComponent.split(separator: " ")
        guard parts.count >= 2, parts.last?.allSatisfy(\.isNumber) == true else {
            return nil
        }

        return parts.dropLast().joined(separator: " ")
    }

    private func managedTopLevelFolderNames(for items: [BackupItem], settings: BackupSettings) -> Set<String> {
        Set(
            items
                .filter { settings.isEnabled($0) }
                .compactMap { $0.destinationPath.split(separator: "/").first.map(String.init) }
        )
    }

    private func snapshotFolderName(for date: Date) -> String {
        Self.snapshotDateFormatter.string(from: date)
    }

    private func snapshotDate(from folderName: String) -> Date? {
        Self.snapshotDateFormatter.date(from: folderName)
    }

    private func copyItem(from sourceURL: URL, to destinationURL: URL, item: BackupItem) throws -> CopyStats {
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)

        let sourceValues = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        if sourceValues.isSymbolicLink == true {
            return CopyStats()
        }

        if item.syncsRepositoryDevFiles {
            return try copyRepositoryDevFiles(from: sourceURL, to: destinationURL)
        }

        if isDirectory.boolValue {
            return try copyDirectory(from: sourceURL, to: destinationURL, excluding: Set(item.excludedRelativePaths))
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        let byteCount = try byteCount(for: destinationURL)
        return CopyStats(fileCount: 1, byteCount: byteCount)
    }

    private func copyRepositoryDevFiles(from sourceURL: URL, to destinationURL: URL) throws -> CopyStats {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let contents = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: []
        )

        var stats = CopyStats()
        for sourceChild in contents where isRepositoryDevRootItem(sourceChild.lastPathComponent) {
            let destinationChild = destinationURL.appendingPathComponent(sourceChild.lastPathComponent)
            let values = try sourceChild.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])

            guard values.isSymbolicLink != true else {
                continue
            }

            if values.isDirectory == true, sourceChild.lastPathComponent == ".vscode" {
                stats.merge(try copyDirectory(from: sourceChild, to: destinationChild, excluding: []))
            } else if values.isRegularFile == true {
                try fileManager.copyItem(at: sourceChild, to: destinationChild)
                stats.fileCount += 1
                stats.byteCount += UInt64(values.fileSize ?? 0)
            }
        }

        stats.merge(try copyRepositoryNamedDevFiles(from: sourceURL, to: destinationURL))
        return stats
    }

    private func isRepositoryDevRootItem(_ fileName: String) -> Bool {
        if fileName == "fabfile_local.py" || fileName == "local_settings.py" || fileName == ".vscode" {
            return true
        }

        return isRepositoryEnvFile(fileName)
    }

    private func isRepositoryEnvFile(_ fileName: String) -> Bool {
        guard fileName == ".env" || fileName.hasPrefix(".env.") else {
            return false
        }

        let excludedNames: Set<String> = [
            ".env.example",
            ".env.sample",
            ".env.template"
        ]
        return !excludedNames.contains(fileName.lowercased())
    }

    private func copyRepositoryNamedDevFiles(from sourceURL: URL, to destinationURL: URL) throws -> CopyStats {
        let includedFileNames: Set<String> = [
            "fabfile_local.py",
            "local_settings.py"
        ]
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return CopyStats()
        }

        var stats = CopyStats()
        let sourcePath = sourceURL.standardizedFileURL.path
        for case let sourceChild as URL in enumerator {
            let values = try sourceChild.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            let relativePath = relativePath(from: sourcePath, to: sourceChild.standardizedFileURL.path)

            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isDirectory == true {
                if shouldSkipRepositoryDevDirectory(sourceChild.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true,
                  includedFileNames.contains(sourceChild.lastPathComponent),
                  !BackupPathFilter.shouldExclude(relativePath: relativePath)
            else {
                continue
            }

            let destinationChild = destinationURL.appendingRelativePath(relativePath)
            guard !fileManager.fileExists(atPath: destinationChild.path) else {
                continue
            }

            try fileManager.createDirectory(
                at: destinationChild.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceChild, to: destinationChild)
            stats.fileCount += 1
            stats.byteCount += UInt64(values.fileSize ?? 0)
        }

        return stats
    }

    private func shouldSkipRepositoryDevDirectory(_ directoryName: String) -> Bool {
        let excludedNames: Set<String> = [
            ".build",
            ".git",
            ".mypy_cache",
            ".pytest_cache",
            ".ruff_cache",
            ".tox",
            ".venv",
            "__pycache__",
            "build",
            "dist",
            "node_modules",
            "venv"
        ]
        return excludedNames.contains(directoryName.lowercased())
    }

    private func relativePath(from rootPath: String, to childPath: String) -> String {
        guard childPath.hasPrefix(rootPath + "/") else {
            return URL(fileURLWithPath: childPath).lastPathComponent
        }

        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private func copyDirectory(from sourceURL: URL, to destinationURL: URL, excluding excludedPaths: Set<String>) throws -> CopyStats {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var stats = CopyStats()
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            return stats
        }

        let canonicalSourcePath = sourceURL.resolvingSymlinksInPath().path

        for case let sourceChild as URL in enumerator {
            let resourceValues = try sourceChild.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            if resourceValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            let canonicalChildPath = sourceChild.resolvingSymlinksInPath().path
            guard canonicalChildPath.hasPrefix(canonicalSourcePath + "/") else {
                continue
            }

            let relativePath = String(canonicalChildPath.dropFirst(canonicalSourcePath.count + 1))
            if shouldExclude(relativePath: relativePath, excludedPaths: excludedPaths) {
                enumerator.skipDescendants()
                continue
            }

            let destinationChild = destinationURL.appendingRelativePath(relativePath)

            if resourceValues.isDirectory == true {
                try fileManager.createDirectory(at: destinationChild, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: destinationChild.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: sourceChild, to: destinationChild)
                stats.fileCount += 1
                stats.byteCount += UInt64(resourceValues.fileSize ?? 0)
            }
        }

        return stats
    }

    private func shouldExclude(relativePath: String, excludedPaths: Set<String>) -> Bool {
        if BackupPathFilter.shouldExclude(relativePath: relativePath) {
            return true
        }

        return excludedPaths.contains { excludedPath in
            if relativePath == excludedPath || relativePath.hasPrefix(excludedPath + "/") {
                return true
            }

            if !excludedPath.contains("/") {
                return relativePath.split(separator: "/").contains(Substring(excludedPath))
            }

            return false
        }
    }

    private func byteCount(for url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values.fileSize ?? 0)
    }

    private func fileRecords(
        for item: BackupItem,
        sourceURL: URL,
        backupURL: URL
    ) throws -> [BackupManifestFile] {
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: backupURL.path, isDirectory: &isDirectory)

        if !isDirectory.boolValue {
            return [
                try fileRecord(
                    for: item,
                    sourceURL: sourceURL,
                    backupFileURL: backupURL,
                    relativePath: ""
                )
            ]
        }

        guard let enumerator = fileManager.enumerator(
            at: backupURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        let rootPath = backupURL.standardizedFileURL.path
        var records: [BackupManifestFile] = []
        for case let childURL as URL in enumerator {
            let values = try childURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            let childPath = childURL.standardizedFileURL.path
            guard childPath.hasPrefix(rootPath + "/") else {
                continue
            }

            let relativePath = String(childPath.dropFirst(rootPath.count + 1))
            guard !BackupPathFilter.shouldExclude(relativePath: relativePath) else {
                continue
            }

            records.append(try fileRecord(
                for: item,
                sourceURL: sourceURL.appendingRelativePath(relativePath),
                backupFileURL: childURL,
                relativePath: relativePath
            ))
        }

        return records
    }

    private func fileRecord(
        for item: BackupItem,
        sourceURL: URL,
        backupFileURL: URL,
        relativePath: String
    ) throws -> BackupManifestFile {
        let values = try backupFileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let backupRelativePath = relativePath.isEmpty
            ? item.destinationPath
            : "\(item.destinationPath)/\(relativePath)"

        return BackupManifestFile(
            itemID: item.id,
            itemDisplayName: item.displayName,
            relativePath: relativePath,
            backupRelativePath: backupRelativePath,
            sourcePath: sourceURL.standardizedFileURL.path,
            byteCount: UInt64(values.fileSize ?? 0),
            sha256: try sha256(for: backupFileURL),
            modifiedAt: values.contentModificationDate
        )
    }

    private func manifestTombstones(
        from settings: BackupSettings,
        copiedFiles: [BackupManifestFile]
    ) -> [SyncTombstone] {
        let copiedPaths = Set(copiedFiles.map(\.backupRelativePath))

        return settings.syncTombstones.values
            .filter { !copiedPaths.contains($0.backupRelativePath) }
            .filter { !BackupPathFilter.shouldExclude(relativePath: $0.backupRelativePath) }
            .sorted { first, second in
                first.backupRelativePath.localizedStandardCompare(second.backupRelativePath) == .orderedAscending
            }
    }

    private func sha256(for url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension BackupService {
    static let snapshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
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

    mutating func merge(_ other: CopyStats) {
        fileCount += other.fileCount
        byteCount += other.byteCount
    }
}
