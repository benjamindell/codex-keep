import Foundation

public final class SettingsStore {
    private let fileManager: FileManager
    private let settingsURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public private(set) var settings: BackupSettings

    public init(
        fileManager: FileManager = .default,
        settingsURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.settingsURL = settingsURL ?? Self.defaultSettingsURL(fileManager: fileManager)

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        if let data = try? Data(contentsOf: self.settingsURL),
           let decoded = try? self.decoder.decode(BackupSettings.self, from: data) {
            var migrated = decoded
            migrated.enabledItemIDs.formUnion(
                DefaultBackupItems.items(homeDirectory: homeDirectory, fileManager: fileManager).map(\.id)
            )
            self.settings = migrated
            if migrated != decoded {
                try? save()
            }
        } else {
            self.settings = BackupSettings.defaults(homeDirectory: homeDirectory, fileManager: fileManager)
        }
    }

    public func update(_ mutate: (inout BackupSettings) -> Void) throws {
        mutate(&settings)
        try save()
    }

    public func save() throws {
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    public static func defaultSettingsURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")

        return appSupport
            .appendingPathComponent("Codex Keep", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}
