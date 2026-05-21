import Foundation

public struct BackupSettings: Codable, Equatable, Sendable {
    public var destinationRootPath: String
    public var enabledItemIDs: Set<String>
    public var backupIntervalMinutes: Int

    public init(
        destinationRootPath: String,
        enabledItemIDs: Set<String>,
        backupIntervalMinutes: Int = 30
    ) {
        self.destinationRootPath = destinationRootPath
        self.enabledItemIDs = enabledItemIDs
        self.backupIntervalMinutes = backupIntervalMinutes
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
            enabledItemIDs: Set(DefaultBackupItems.items(homeDirectory: homeDirectory).map(\.id))
        )
    }
}
