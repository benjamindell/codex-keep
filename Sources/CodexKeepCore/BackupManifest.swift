import Foundation

public struct BackupManifest: Codable, Equatable, Sendable {
    public var appName: String
    public var schemaVersion: Int
    public var createdAt: Date
    public var machineName: String
    public var items: [BackupManifestItem]
    public var files: [BackupManifestFile]
    public var tombstones: [SyncTombstone]
    public var warnings: [String]

    public init(
        appName: String,
        schemaVersion: Int,
        createdAt: Date,
        machineName: String,
        items: [BackupManifestItem],
        files: [BackupManifestFile] = [],
        tombstones: [SyncTombstone] = [],
        warnings: [String]
    ) {
        self.appName = appName
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.machineName = machineName
        self.items = items
        self.files = files
        self.tombstones = tombstones
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case appName
        case schemaVersion
        case createdAt
        case machineName
        case items
        case files
        case tombstones
        case warnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appName = try container.decode(String.self, forKey: .appName)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.machineName = try container.decode(String.self, forKey: .machineName)
        self.items = try container.decode([BackupManifestItem].self, forKey: .items)
        self.files = try container.decodeIfPresent([BackupManifestFile].self, forKey: .files) ?? []
        self.tombstones = try container.decodeIfPresent([SyncTombstone].self, forKey: .tombstones) ?? []
        self.warnings = try container.decode([String].self, forKey: .warnings)
    }
}

public struct BackupManifestItem: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case copied
        case missing
        case failed
    }

    public var id: String
    public var displayName: String
    public var sourcePath: String
    public var destinationPath: String
    public var status: Status
    public var fileCount: Int
    public var byteCount: UInt64
    public var message: String?
}

public struct BackupResult: Equatable, Sendable {
    public var manifest: BackupManifest
    public var latestURL: URL

    public var copiedItemCount: Int {
        manifest.items.filter { $0.status == .copied }.count
    }
}

public struct BackupManifestFile: Codable, Equatable, Sendable {
    public var itemID: String
    public var itemDisplayName: String
    public var relativePath: String
    public var backupRelativePath: String
    public var sourcePath: String
    public var byteCount: UInt64
    public var sha256: String
    public var modifiedAt: Date?

    public init(
        itemID: String,
        itemDisplayName: String,
        relativePath: String,
        backupRelativePath: String,
        sourcePath: String,
        byteCount: UInt64,
        sha256: String,
        modifiedAt: Date?
    ) {
        self.itemID = itemID
        self.itemDisplayName = itemDisplayName
        self.relativePath = relativePath
        self.backupRelativePath = backupRelativePath
        self.sourcePath = sourcePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.modifiedAt = modifiedAt
    }
}
