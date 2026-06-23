import CryptoKit
import Foundation

public enum PeerSyncServiceError: LocalizedError, Equatable {
    case missingPeerManifest(String)
    case unreadablePeerManifest(String, String)
    case unsupportedManifestVersion(Int)
    case noSelectedItems
    case unableToCreateSafetySnapshot(String)
    case unableToSync(String)

    public var errorDescription: String? {
        switch self {
        case let .missingPeerManifest(path):
            "No Codex Keep manifest was found at \(path)."
        case let .unreadablePeerManifest(path, reason):
            "The Codex Keep manifest at \(path) could not be read: \(reason)"
        case let .unsupportedManifestVersion(version):
            "Codex Keep cannot sync schema version \(version)."
        case .noSelectedItems:
            "No peer changes were selected."
        case let .unableToCreateSafetySnapshot(message):
            "Could not create the sync safety snapshot: \(message)"
        case let .unableToSync(message):
            "Could not sync peer changes: \(message)"
        }
    }
}

public struct PeerSyncPlan: Equatable, Sendable {
    public var peerName: String
    public var sourceURL: URL
    public var manifest: BackupManifest
    public var items: [PeerSyncPlanItem]
    public var warnings: [String]

    public var automaticItemIDs: Set<String> {
        Set(items.filter(\.isAutomatic).map(\.id))
    }

    public var reviewItemCount: Int {
        items.filter(\.needsReview).count
    }

    public var incomingItemCount: Int {
        items.filter(\.isAutomatic).count
    }
}

public struct PeerSyncPlanItem: Equatable, Identifiable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case incomingNew
        case incomingChanged
        case unchanged
        case localChanged
        case conflict
        case peerDeletedReviewRequired
    }

    public var id: String
    public var peerName: String
    public var displayName: String
    public var backupRelativePath: String
    public var targetPath: String
    public var status: Status
    public var peerSHA256: String?
    public var localSHA256: String?
    public var byteCount: UInt64
    public var deletedAt: Date?

    public var isAutomatic: Bool {
        status == .incomingNew || status == .incomingChanged
    }

    public var needsReview: Bool {
        status == .conflict || status == .peerDeletedReviewRequired
    }

    public var replacesLocalWhenReviewed: Bool {
        status == .conflict
            && peerSHA256 != nil
            && backupRelativePath == "Codex/config.toml"
    }
}

public struct PeerSyncApplyResult: Equatable, Sendable {
    public var appliedItemCount: Int
    public var conflictCopyCount: Int
    public var deletedItemCount: Int
    public var skippedItemCount: Int
    public var skippedBackupRelativePaths: [String]
    public var safetySnapshotURL: URL
    public var updatedSettings: BackupSettings
}

public final class PeerSyncService {
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

    public func availablePeerMachineNames(settings: BackupSettings) -> [String] {
        let rootURL = URL(fileURLWithPath: settings.destinationRootPath).standardizedFileURL
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let currentMachine = Machine.currentName()
        return contents.compactMap { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  url.lastPathComponent != currentMachine
            else {
                return nil
            }

            return hasPeerBackup(at: url) ? url.lastPathComponent : nil
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func settingsByRecordingLocalState(
        _ settings: BackupSettings,
        localManifest: BackupManifest,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        items: [BackupItem]? = nil,
        now: Date = Date()
    ) -> BackupSettings {
        let restoreItems = items ?? DefaultBackupItems.items(homeDirectory: homeDirectory, fileManager: fileManager)
        let enabledDestinationPaths = Set(
            restoreItems
                .filter { settings.isEnabled($0) }
                .map(\.destinationPath)
        )
        let localFiles = Dictionary(uniqueKeysWithValues: localManifest.files.map { ($0.backupRelativePath, $0) })
        var updated = settings

        for file in localManifest.files where isSyncableBackupPath(file.backupRelativePath) {
            updated.syncTombstones.removeValue(forKey: file.backupRelativePath)
        }

        for (backupRelativePath, state) in settings.syncStates where state.sha256 != nil {
            guard isSyncableBackupPath(backupRelativePath),
                  isManaged(backupRelativePath: backupRelativePath, by: enabledDestinationPaths),
                  localFiles[backupRelativePath] == nil
            else {
                continue
            }

            updated.syncStates[backupRelativePath] = SyncFileState(
                sha256: nil,
                updatedAt: now,
                machineName: Machine.currentName()
            )
            updated.syncTombstones[backupRelativePath] = SyncTombstone(
                backupRelativePath: backupRelativePath,
                deletedAt: now,
                machineName: Machine.currentName()
            )
        }

        return updated
    }

    public func makePlans(
        settings: BackupSettings,
        localManifest: BackupManifest,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        items: [BackupItem]? = nil
    ) throws -> [PeerSyncPlan] {
        let peerNames = settings.trustedMachineNames.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let restoreItems = items ?? DefaultBackupItems.items(homeDirectory: homeDirectory, fileManager: fileManager)
        let enabledItems = restoreItems.filter { settings.isEnabled($0) }
        let localFiles = Dictionary(uniqueKeysWithValues: localManifest.files.map { ($0.backupRelativePath, $0) })

        return try peerNames.compactMap { peerName in
            let sourceURL = URL(fileURLWithPath: settings.destinationRootPath)
                .standardizedFileURL
                .appendingPathComponent(peerName, isDirectory: true)
                .appendingPathComponent("latest", isDirectory: true)
            let manifest: BackupManifest
            do {
                manifest = try readManifest(at: sourceURL)
            } catch PeerSyncServiceError.missingPeerManifest {
                return nil
            } catch PeerSyncServiceError.unreadablePeerManifest {
                return nil
            }
            let syncablePeerFiles = manifest.files.filter { isSyncableBackupPath($0.backupRelativePath) }
            let peerFiles = Dictionary(uniqueKeysWithValues: syncablePeerFiles.map { ($0.backupRelativePath, $0) })
            let peerTombstones = Dictionary(uniqueKeysWithValues: manifest.tombstones.map { ($0.backupRelativePath, $0) })
            var planItems: [PeerSyncPlanItem] = []

            for peerFile in syncablePeerFiles {
                guard let targetURL = targetURL(
                    for: peerFile.backupRelativePath,
                    items: enabledItems
                ) else {
                    continue
                }

                let localFile = localFiles[peerFile.backupRelativePath]
                let status = fileStatus(
                    localFile: localFile,
                    peerFile: peerFile,
                    syncedState: settings.syncStates[peerFile.backupRelativePath]
                )

                planItems.append(PeerSyncPlanItem(
                    id: planItemID(
                        peerName: peerName,
                        status: status,
                        backupRelativePath: peerFile.backupRelativePath
                    ),
                    peerName: peerName,
                    displayName: displayName(for: peerFile),
                    backupRelativePath: peerFile.backupRelativePath,
                    targetPath: targetURL.path,
                    status: status,
                    peerSHA256: peerFile.sha256,
                    localSHA256: localFile?.sha256,
                    byteCount: peerFile.byteCount,
                    deletedAt: nil
                ))
            }

            for tombstone in peerTombstones.values where peerFiles[tombstone.backupRelativePath] == nil {
                guard isSyncableBackupPath(tombstone.backupRelativePath),
                      shouldSyncPeerDeletion(backupRelativePath: tombstone.backupRelativePath)
                else {
                    continue
                }

                guard let targetURL = targetURL(
                    for: tombstone.backupRelativePath,
                    items: enabledItems
                ),
                    let localFile = localFiles[tombstone.backupRelativePath],
                    shouldReviewPeerDeletion(
                        syncedState: settings.syncStates[tombstone.backupRelativePath]
                    )
                else {
                    continue
                }

                let status: PeerSyncPlanItem.Status = settings.syncStates[tombstone.backupRelativePath]?.sha256 == localFile.sha256
                    ? .peerDeletedReviewRequired
                    : .conflict

                planItems.append(PeerSyncPlanItem(
                    id: planItemID(
                        peerName: peerName,
                        status: status,
                        backupRelativePath: tombstone.backupRelativePath
                    ),
                    peerName: peerName,
                    displayName: "Deleted by \(tombstone.machineName): \(tombstone.backupRelativePath)",
                    backupRelativePath: tombstone.backupRelativePath,
                    targetPath: targetURL.path,
                    status: status,
                    peerSHA256: nil,
                    localSHA256: localFile.sha256,
                    byteCount: localFile.byteCount,
                    deletedAt: tombstone.deletedAt
                ))
            }

            return PeerSyncPlan(
                peerName: peerName,
                sourceURL: sourceURL,
                manifest: manifest,
                items: planItems.sorted(by: sortPlanItems),
                warnings: manifest.warnings
            )
        }
    }

    public func settingsByRecordingUnchangedPeerFiles(
        _ settings: BackupSettings,
        plans: [PeerSyncPlan],
        now: Date = Date()
    ) -> BackupSettings {
        var updated = settings

        for plan in plans {
            for item in plan.items where item.status == .unchanged {
                guard let sha256 = item.peerSHA256 else {
                    continue
                }

                updated.syncStates[item.backupRelativePath] = SyncFileState(
                    sha256: sha256,
                    updatedAt: now,
                    machineName: plan.peerName
                )
                updated.syncTombstones.removeValue(forKey: item.backupRelativePath)
            }
        }

        return updated
    }

    public func apply(
        plans: [PeerSyncPlan],
        selectedItemIDs: Set<String>,
        settings: BackupSettings,
        now: Date = Date()
    ) throws -> PeerSyncApplyResult {
        let selectedItemsByPlan = plans.map { plan in
            (plan, plan.items.filter { selectedItemIDs.contains($0.id) })
        }
        let selectedItems = selectedItemsByPlan.flatMap(\.1)
        guard !selectedItems.isEmpty else {
            throw PeerSyncServiceError.noSelectedItems
        }

        let safetySnapshotURL: URL
        do {
            safetySnapshotURL = try createSafetySnapshot(
                for: selectedItems,
                settings: settings,
                now: now
            )
        } catch {
            throw PeerSyncServiceError.unableToCreateSafetySnapshot(error.localizedDescription)
        }

        var updatedSettings = settings
        var appliedItemCount = 0
        var conflictCopyCount = 0
        var deletedItemCount = 0
        var skippedItemCount = 0
        var skippedBackupRelativePaths: [String] = []
        var extractedPayloads: [String: URL] = [:]
        let peerDownloadDeadline = Date().addingTimeInterval(120)
        defer {
            for url in extractedPayloads.values {
                try? fileManager.removeItem(at: url)
            }
        }

        do {
            for (plan, items) in selectedItemsByPlan {
                for item in items {
                    switch item.status {
                    case .incomingNew, .incomingChanged:
                        guard let sourceURL = try preparedPeerSourceFile(
                            plan: plan,
                            backupRelativePath: item.backupRelativePath,
                            extractedPayloads: &extractedPayloads,
                            waitUntil: peerDownloadDeadline
                        ) else {
                            skippedItemCount += 1
                            skippedBackupRelativePaths.append(item.backupRelativePath)
                            continue
                        }

                        try replaceFile(from: sourceURL, to: URL(fileURLWithPath: item.targetPath))
                        try verifyReplacement(
                            targetURL: URL(fileURLWithPath: item.targetPath),
                            expectedSHA256: item.peerSHA256,
                            backupRelativePath: item.backupRelativePath
                        )
                        updatedSettings.syncStates[item.backupRelativePath] = SyncFileState(
                            sha256: item.peerSHA256,
                            updatedAt: now,
                            machineName: plan.peerName
                        )
                        updatedSettings.syncTombstones.removeValue(forKey: item.backupRelativePath)
                        appliedItemCount += 1
                    case .conflict where item.peerSHA256 != nil:
                        guard let sourceURL = try preparedPeerSourceFile(
                            plan: plan,
                            backupRelativePath: item.backupRelativePath,
                            extractedPayloads: &extractedPayloads,
                            waitUntil: peerDownloadDeadline
                        ) else {
                            skippedItemCount += 1
                            skippedBackupRelativePaths.append(item.backupRelativePath)
                            continue
                        }

                        if item.replacesLocalWhenReviewed {
                            try replaceFile(from: sourceURL, to: URL(fileURLWithPath: item.targetPath))
                            try verifyReplacement(
                                targetURL: URL(fileURLWithPath: item.targetPath),
                                expectedSHA256: item.peerSHA256,
                                backupRelativePath: item.backupRelativePath
                            )
                            updatedSettings.syncStates[item.backupRelativePath] = SyncFileState(
                                sha256: item.peerSHA256,
                                updatedAt: now,
                                machineName: plan.peerName
                            )
                            updatedSettings.syncTombstones.removeValue(forKey: item.backupRelativePath)
                            appliedItemCount += 1
                        } else {
                            try copyConflictFile(
                                from: sourceURL,
                                beside: URL(fileURLWithPath: item.targetPath),
                                peerName: plan.peerName,
                                now: now
                            )
                            conflictCopyCount += 1
                        }
                    case .peerDeletedReviewRequired:
                        let targetURL = URL(fileURLWithPath: item.targetPath)
                        if fileManager.fileExists(atPath: targetURL.path) {
                            try fileManager.removeItem(at: targetURL)
                        }
                        updatedSettings.syncStates[item.backupRelativePath] = SyncFileState(
                            sha256: nil,
                            updatedAt: now,
                            machineName: plan.peerName
                        )
                        updatedSettings.syncTombstones[item.backupRelativePath] = SyncTombstone(
                            backupRelativePath: item.backupRelativePath,
                            deletedAt: now,
                            machineName: Machine.currentName()
                        )
                        deletedItemCount += 1
                    case .conflict, .localChanged, .unchanged:
                        continue
                    }
                }
            }
        } catch {
            throw PeerSyncServiceError.unableToSync(error.localizedDescription)
        }

        updatedSettings = settingsByRecordingUnchangedPeerFiles(updatedSettings, plans: plans, now: now)

        return PeerSyncApplyResult(
            appliedItemCount: appliedItemCount,
            conflictCopyCount: conflictCopyCount,
            deletedItemCount: deletedItemCount,
            skippedItemCount: skippedItemCount,
            skippedBackupRelativePaths: skippedBackupRelativePaths,
            safetySnapshotURL: safetySnapshotURL,
            updatedSettings: updatedSettings
        )
    }

    private func readManifest(at sourceURL: URL) throws -> BackupManifest {
        let manifestURL = sourceURL.appendingPathComponent("manifest.json")
        try? fileManager.startDownloadingUbiquitousItem(at: sourceURL)
        try? fileManager.startDownloadingUbiquitousItem(at: manifestURL)

        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw PeerSyncServiceError.missingPeerManifest(manifestURL.path)
        }

        let manifest: BackupManifest
        do {
            manifest = try decoder.decode(BackupManifest.self, from: manifestData)
        } catch {
            throw PeerSyncServiceError.unreadablePeerManifest(manifestURL.path, error.localizedDescription)
        }
        guard manifest.schemaVersion == 1 else {
            throw PeerSyncServiceError.unsupportedManifestVersion(manifest.schemaVersion)
        }

        return manifest
    }

    private func hasPeerBackup(at machineURL: URL) -> Bool {
        let latestURL = machineURL.appendingPathComponent("latest", isDirectory: true)
        let snapshotsURL = machineURL.appendingPathComponent("Snapshots", isDirectory: true)
        let manifestURL = latestURL.appendingPathComponent("manifest.json")

        try? fileManager.startDownloadingUbiquitousItem(at: machineURL)
        try? fileManager.startDownloadingUbiquitousItem(at: latestURL)
        try? fileManager.startDownloadingUbiquitousItem(at: manifestURL)

        return fileManager.fileExists(atPath: manifestURL.path)
            || fileManager.fileExists(atPath: latestURL.path)
            || fileManager.fileExists(atPath: snapshotsURL.path)
    }

    private func fileStatus(
        localFile: BackupManifestFile?,
        peerFile: BackupManifestFile,
        syncedState: SyncFileState?
    ) -> PeerSyncPlanItem.Status {
        guard let localFile else {
            return .incomingNew
        }

        if localFile.sha256 == peerFile.sha256 {
            return .unchanged
        }

        guard let syncedSHA256 = syncedState?.sha256 else {
            return .conflict
        }

        let localChanged = localFile.sha256 != syncedSHA256
        let peerChanged = peerFile.sha256 != syncedSHA256

        switch (localChanged, peerChanged) {
        case (false, true):
            return .incomingChanged
        case (true, false):
            return .localChanged
        case (true, true):
            return .conflict
        case (false, false):
            return .unchanged
        }
    }

    private func shouldReviewPeerDeletion(syncedState: SyncFileState?) -> Bool {
        syncedState?.sha256 != nil
    }

    private func shouldSyncPeerDeletion(backupRelativePath: String) -> Bool {
        backupRelativePath != "Codex/config.toml"
    }

    private func isSyncableBackupPath(_ backupRelativePath: String) -> Bool {
        !backupRelativePath.hasPrefix("Codex/automations/")
            && backupRelativePath != "Codex/automations"
            && !BackupPathFilter.shouldExclude(relativePath: backupRelativePath)
    }

    private func targetURL(for backupRelativePath: String, items: [BackupItem]) -> URL? {
        for item in items {
            if backupRelativePath == item.destinationPath {
                return URL(fileURLWithPath: item.sourcePath)
            }

            let prefix = item.destinationPath + "/"
            if backupRelativePath.hasPrefix(prefix) {
                let suffix = String(backupRelativePath.dropFirst(prefix.count))
                return URL(fileURLWithPath: item.sourcePath).appendingRelativePath(suffix)
            }
        }

        return nil
    }

    private func displayName(for file: BackupManifestFile) -> String {
        if file.relativePath.isEmpty {
            return file.itemDisplayName
        }

        return "\(file.itemDisplayName): \(file.relativePath)"
    }

    private func isManaged(backupRelativePath: String, by destinationPaths: Set<String>) -> Bool {
        destinationPaths.contains { destinationPath in
            backupRelativePath == destinationPath || backupRelativePath.hasPrefix(destinationPath + "/")
        }
    }

    private func createSafetySnapshot(
        for items: [PeerSyncPlanItem],
        settings: BackupSettings,
        now: Date
    ) throws -> URL {
        let machineRoot = URL(fileURLWithPath: settings.destinationRootPath)
            .standardizedFileURL
            .appendingPathComponent(Machine.currentName(), isDirectory: true)
        let safetySnapshotURL = machineRoot
            .appendingPathComponent("Sync Safety", isDirectory: true)
            .appendingPathComponent(safetySnapshotFolderName(for: now), isDirectory: true)

        try fileManager.createDirectory(at: safetySnapshotURL, withIntermediateDirectories: true)

        var snapshotItems: [BackupManifestItem] = []
        var snapshotTargetPaths: Set<String> = []
        for item in items {
            guard snapshotTargetPaths.insert(item.targetPath).inserted else {
                continue
            }

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
                    message: "No local item existed before sync."
                ))
                continue
            }

            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try copyReplacingDestination(from: sourceURL, to: destinationURL)
                snapshotItems.append(BackupManifestItem(
                    id: item.id,
                    displayName: item.displayName,
                    sourcePath: sourceURL.path,
                    destinationPath: destinationURL.path,
                    status: .copied,
                    fileCount: 1,
                    byteCount: item.byteCount,
                    message: nil
                ))
            } catch where isMissingFileError(error) {
                snapshotItems.append(BackupManifestItem(
                    id: item.id,
                    displayName: item.displayName,
                    sourcePath: sourceURL.path,
                    destinationPath: destinationURL.path,
                    status: .missing,
                    fileCount: 0,
                    byteCount: 0,
                    message: "The local item disappeared before sync."
                ))
            }
        }

        let manifest = BackupManifest(
            appName: "Codex Keep Sync Safety",
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

    private func preparedPeerSourceFile(
        plan: PeerSyncPlan,
        backupRelativePath: String,
        extractedPayloads: inout [String: URL],
        waitUntil deadline: Date
    ) throws -> URL? {
        let sourceURL = plan.sourceURL.appendingRelativePath(backupRelativePath)
        if preparePeerSourceFile(at: sourceURL, waitUntil: Date(), waitForMissingFile: false) {
            return sourceURL
        }

        guard let extractionURL = try preparedPayloadExtractionURL(
            for: plan,
            extractedPayloads: &extractedPayloads,
            waitUntil: deadline
        ) else {
            return nil
        }

        let extractedSourceURL = extractionURL.appendingRelativePath(backupRelativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: extractedSourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return nil
        }

        return extractedSourceURL
    }

    private func preparedPayloadExtractionURL(
        for plan: PeerSyncPlan,
        extractedPayloads: inout [String: URL],
        waitUntil deadline: Date
    ) throws -> URL? {
        let payloadKey = plan.sourceURL.standardizedFileURL.path
        if let existingURL = extractedPayloads[payloadKey] {
            return existingURL
        }

        let payloadURL = plan.sourceURL.appendingPathComponent(PayloadArchive.fileName)
        let shouldWait = isLikelyICloudURL(payloadURL)
        repeat {
            try? fileManager.startDownloadingUbiquitousItem(at: plan.sourceURL)
            try? fileManager.startDownloadingUbiquitousItem(at: payloadURL)

            if fileManager.fileExists(atPath: payloadURL.path) {
                let extractionURL = fileManager.temporaryDirectory
                    .appendingPathComponent("codex-keep-peer-\(UUID().uuidString)", isDirectory: true)

                do {
                    try PayloadArchive.extract(archiveURL: payloadURL, to: extractionURL)
                    extractedPayloads[payloadKey] = extractionURL
                    return extractionURL
                } catch {
                    try? fileManager.removeItem(at: extractionURL)
                    if !shouldWait || Date() >= deadline {
                        throw error
                    }
                }
            } else if !shouldWait {
                return nil
            }

            guard Date() < deadline else {
                return nil
            }

            Thread.sleep(forTimeInterval: 1)
        } while true
    }

    private func preparePeerSourceFile(
        at sourceURL: URL,
        waitUntil deadline: Date,
        waitForMissingFile: Bool
    ) -> Bool {
        try? fileManager.startDownloadingUbiquitousItem(at: sourceURL)

        repeat {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               isReadyForImmediateRead(sourceURL) {
                return true
            }

            if !waitForMissingFile && !fileManager.fileExists(atPath: sourceURL.path) {
                return false
            }

            guard Date() < deadline else {
                return false
            }

            Thread.sleep(forTimeInterval: 0.2)
        } while true
    }

    private func isLikelyICloudURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

    private func isReadyForImmediateRead(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]),
              values.isUbiquitousItem == true
        else {
            return true
        }

        return values.ubiquitousItemDownloadingStatus == .current
            || values.ubiquitousItemDownloadingStatus == .downloaded
    }

    private func replaceFile(from sourceURL: URL, to targetURL: URL) throws {
        let targetParentURL = targetURL.deletingLastPathComponent()
        let stagingURL = targetParentURL.appendingPathComponent(".codex-keep-sync-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: targetParentURL, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
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

    private func verifyReplacement(
        targetURL: URL,
        expectedSHA256: String?,
        backupRelativePath: String
    ) throws {
        guard let expectedSHA256 else {
            return
        }

        let actualSHA256 = try sha256(for: targetURL)
        guard actualSHA256 == expectedSHA256 else {
            throw PeerSyncServiceError.unableToSync(
                "\(backupRelativePath) was copied but did not match the peer file hash afterward."
            )
        }
    }

    private func sha256(for url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func copyReplacingDestination(from sourceURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileReadNoSuchFileError
    }

    private func copyConflictFile(
        from sourceURL: URL,
        beside targetURL: URL,
        peerName: String,
        now: Date
    ) throws {
        let conflictURL = conflictURL(beside: targetURL, peerName: peerName, now: now)
        try fileManager.createDirectory(at: conflictURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: conflictURL.path) {
            try fileManager.removeItem(at: conflictURL)
        }
        try fileManager.copyItem(at: sourceURL, to: conflictURL)
    }

    private func conflictURL(beside targetURL: URL, peerName: String, now: Date) -> URL {
        let sanitizedPeer = peerName.replacingOccurrences(of: "/", with: "-")
        let stamp = Self.conflictDateFormatter.string(from: now)
        let base = targetURL.deletingPathExtension().lastPathComponent
        let ext = targetURL.pathExtension
        let filename = ext.isEmpty
            ? "\(base).conflict-\(sanitizedPeer)-\(stamp)"
            : "\(base).conflict-\(sanitizedPeer)-\(stamp).\(ext)"

        return targetURL.deletingLastPathComponent().appendingPathComponent(filename)
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

    private func planItemID(
        peerName: String,
        status: PeerSyncPlanItem.Status,
        backupRelativePath: String
    ) -> String {
        "\(peerName)|\(status.rawValue)|\(backupRelativePath)"
    }

    private func sortPlanItems(_ first: PeerSyncPlanItem, _ second: PeerSyncPlanItem) -> Bool {
        if first.status != second.status {
            return sortRank(for: first.status) < sortRank(for: second.status)
        }

        return first.backupRelativePath.localizedStandardCompare(second.backupRelativePath) == .orderedAscending
    }

    private func sortRank(for status: PeerSyncPlanItem.Status) -> Int {
        switch status {
        case .conflict:
            return 0
        case .peerDeletedReviewRequired:
            return 1
        case .incomingChanged:
            return 2
        case .incomingNew:
            return 3
        case .localChanged:
            return 4
        case .unchanged:
            return 5
        }
    }
}

private extension PeerSyncService {
    static let safetySnapshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    static let conflictDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
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
