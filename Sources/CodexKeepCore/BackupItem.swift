import Foundation

public struct BackupItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var sourcePath: String
    public var destinationPath: String
    public var excludedRelativePaths: [String]
    public var required: Bool

    public init(
        id: String,
        displayName: String,
        sourcePath: String,
        destinationPath: String,
        excludedRelativePaths: [String] = [],
        required: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.excludedRelativePaths = excludedRelativePaths
        self.required = required
    }
}

public enum DefaultBackupItems {
    public static func items(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BackupItem] {
        let codexHome = homeDirectory.appendingPathComponent(".codex").path
        let agentsHome = homeDirectory.appendingPathComponent(".agents").path

        return [
            BackupItem(
                id: "codex-automations",
                displayName: "Codex automations",
                sourcePath: "\(codexHome)/automations",
                destinationPath: "Codex/automations",
                excludedRelativePaths: [
                    ".run-jitter-salt"
                ]
            ),
            BackupItem(
                id: "codex-agents",
                displayName: "Global AGENTS.md",
                sourcePath: "\(codexHome)/AGENTS.md",
                destinationPath: "Codex/AGENTS.md"
            ),
            BackupItem(
                id: "codex-config",
                displayName: "Codex config",
                sourcePath: "\(codexHome)/config.toml",
                destinationPath: "Codex/config.toml"
            ),
            BackupItem(
                id: "codex-rules",
                displayName: "Codex rules",
                sourcePath: "\(codexHome)/rules",
                destinationPath: "Codex/rules"
            ),
            BackupItem(
                id: "codex-skills",
                displayName: "Custom Codex skills",
                sourcePath: "\(codexHome)/skills",
                destinationPath: "Codex/skills",
                excludedRelativePaths: [
                    ".system",
                    "codex-primary-runtime"
                ]
            ),
            BackupItem(
                id: "agent-skills",
                displayName: "Agent skills",
                sourcePath: "\(agentsHome)/skills",
                destinationPath: "Agents/skills"
            )
        ]
    }
}
