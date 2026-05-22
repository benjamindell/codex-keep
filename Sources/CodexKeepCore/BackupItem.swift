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
        items(homeDirectory: homeDirectory, fileManager: .default)
    }

    public static func items(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [BackupItem] {
        let codexHomeURL = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let agentsHomeURL = homeDirectory.appendingPathComponent(".agents", isDirectory: true)
        let codexHome = codexHomeURL.path
        let agentsHome = agentsHomeURL.path

        let explicitItems = [
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

        return explicitItems + discoveredMarkdownFolders(
            in: codexHomeURL,
            excluding: Set(explicitItems.map(\.sourcePath)),
            fileManager: fileManager
        )
    }

    private static func discoveredMarkdownFolders(
        in codexHomeURL: URL,
        excluding explicitSourcePaths: Set<String>,
        fileManager: FileManager
    ) -> [BackupItem] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: codexHomeURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        let excludedFolderNames: Set<String> = [
            ".tmp",
            "archived_sessions",
            "browser",
            "cache",
            "computer-use",
            "log",
            "logs",
            "node_repl",
            "plugins",
            "sessions",
            "shell_snapshots",
            "sqlite",
            "tmp",
            "vendor_imports",
            "worktrees"
        ]

        return directories
            .filter { directoryURL in
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    return false
                }

                let folderName = directoryURL.lastPathComponent
                return !folderName.hasPrefix(".")
                    && !excludedFolderNames.contains(folderName)
                    && !explicitSourcePaths.contains(directoryURL.path)
                    && containsMarkdownFile(in: directoryURL, fileManager: fileManager)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { directoryURL in
                let folderName = directoryURL.lastPathComponent
                return BackupItem(
                    id: "codex-markdown-\(folderName)",
                    displayName: "Codex \(folderName)",
                    sourcePath: directoryURL.path,
                    destinationPath: "Codex/\(folderName)"
                )
            }
    }

    private static func containsMarkdownFile(in directoryURL: URL, fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }

        for case let childURL as URL in enumerator {
            guard childURL.pathExtension.lowercased() == "md" else {
                continue
            }

            if (try? childURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }

        return false
    }
}
