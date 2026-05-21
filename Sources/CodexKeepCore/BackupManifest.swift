import Foundation

public struct BackupManifest: Codable, Equatable, Sendable {
    public var appName: String
    public var schemaVersion: Int
    public var createdAt: Date
    public var machineName: String
    public var items: [BackupManifestItem]
    public var warnings: [String]
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
