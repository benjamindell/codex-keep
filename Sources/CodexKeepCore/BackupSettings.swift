import Foundation

public struct BackupSettings: Codable, Equatable, Sendable {
    public var destinationRootPath: String
    public var enabledItemIDs: Set<String>
    public var backupIntervalMinutes: Int
    public var trustedMachineNames: Set<String>
    public var automaticallySyncTrustedMachines: Bool
    public var syncRepositoryDevFiles: Bool
    public var syncStates: [String: SyncFileState]
    public var syncTombstones: [String: SyncTombstone]

    public init(
        destinationRootPath: String,
        enabledItemIDs: Set<String>,
        backupIntervalMinutes: Int = 30,
        trustedMachineNames: Set<String> = [],
        automaticallySyncTrustedMachines: Bool = false,
        syncRepositoryDevFiles: Bool = false,
        syncStates: [String: SyncFileState] = [:],
        syncTombstones: [String: SyncTombstone] = [:]
    ) {
        self.destinationRootPath = destinationRootPath
        self.enabledItemIDs = enabledItemIDs
        self.backupIntervalMinutes = backupIntervalMinutes
        self.trustedMachineNames = trustedMachineNames
        self.automaticallySyncTrustedMachines = automaticallySyncTrustedMachines
        self.syncRepositoryDevFiles = syncRepositoryDevFiles
        self.syncStates = syncStates
        self.syncTombstones = syncTombstones
    }

    enum CodingKeys: String, CodingKey {
        case destinationRootPath
        case enabledItemIDs
        case backupIntervalMinutes
        case trustedMachineNames
        case automaticallySyncTrustedMachines
        case syncRepositoryDevFiles
        case syncStates
        case syncTombstones
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.destinationRootPath = try container.decode(String.self, forKey: .destinationRootPath)
        self.enabledItemIDs = try container.decode(Set<String>.self, forKey: .enabledItemIDs)
        self.backupIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .backupIntervalMinutes) ?? 30
        self.trustedMachineNames = try container.decodeIfPresent(Set<String>.self, forKey: .trustedMachineNames) ?? []
        self.automaticallySyncTrustedMachines = try container.decodeIfPresent(Bool.self, forKey: .automaticallySyncTrustedMachines) ?? false
        self.syncRepositoryDevFiles = try container.decodeIfPresent(Bool.self, forKey: .syncRepositoryDevFiles) ?? false
        self.syncStates = try container.decodeIfPresent([String: SyncFileState].self, forKey: .syncStates) ?? [:]
        self.syncTombstones = try container.decodeIfPresent([String: SyncTombstone].self, forKey: .syncTombstones) ?? [:]
    }

    public static func defaults(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> BackupSettings {
        let iCloudDrive = homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Mobile Documents")
            .appendingPathComponent("com~apple~CloudDocs")

        let destination: URL
        if fileManager.fileExists(atPath: iCloudDrive.path) {
            destination = iCloudDrive.appendingPathComponent("Codex Keep")
        } else {
            destination = homeDirectory.appendingPathComponent("Codex Keep Backups")
        }

        return BackupSettings(
            destinationRootPath: destination.path,
            enabledItemIDs: Set(
                DefaultBackupItems.items(homeDirectory: homeDirectory, fileManager: fileManager)
                    .filter(\.defaultEnabled)
                    .map(\.id)
            )
        )
    }

    public func isEnabled(_ item: BackupItem) -> Bool {
        if item.syncsRepositoryDevFiles {
            return syncRepositoryDevFiles
        }

        return enabledItemIDs.contains(item.id)
    }
}

public struct SyncFileState: Codable, Equatable, Sendable {
    public var sha256: String?
    public var updatedAt: Date
    public var machineName: String

    public init(sha256: String?, updatedAt: Date, machineName: String) {
        self.sha256 = sha256
        self.updatedAt = updatedAt
        self.machineName = machineName
    }
}

public struct SyncTombstone: Codable, Equatable, Sendable {
    public var backupRelativePath: String
    public var deletedAt: Date
    public var machineName: String

    public init(backupRelativePath: String, deletedAt: Date, machineName: String) {
        self.backupRelativePath = backupRelativePath
        self.deletedAt = deletedAt
        self.machineName = machineName
    }
}
