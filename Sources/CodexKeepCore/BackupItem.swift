import Foundation

public struct BackupItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var sourcePath: String
    public var destinationPath: String
    public var excludedRelativePaths: [String]
    public var required: Bool
    public var defaultEnabled: Bool
    public var syncsRepositoryDevFiles: Bool

    public init(
        id: String,
        displayName: String,
        sourcePath: String,
        destinationPath: String,
        excludedRelativePaths: [String] = [],
        required: Bool = false,
        defaultEnabled: Bool = true,
        syncsRepositoryDevFiles: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.excludedRelativePaths = excludedRelativePaths
        self.required = required
        self.defaultEnabled = defaultEnabled
        self.syncsRepositoryDevFiles = syncsRepositoryDevFiles
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
                    "codex-primary-runtime",
                    "node_modules"
                ]
            ),
            BackupItem(
                id: "agent-skills",
                displayName: "Agent skills",
                sourcePath: "\(agentsHome)/skills",
                destinationPath: "Agents/skills"
            ),
            BackupItem(
                id: "aws-credentials",
                displayName: "AWS credentials",
                sourcePath: "\(homeDirectory.path)/.aws/credentials",
                destinationPath: "AWS/credentials",
                defaultEnabled: false,
                syncsRepositoryDevFiles: true
            )
        ]

        return explicitItems + discoveredRepositoryDevFileItems(
            in: homeDirectory.appendingPathComponent("Repositories", isDirectory: true),
            fileManager: fileManager
        ) + discoveredMarkdownFolders(
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
            "state",
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

    private static func discoveredRepositoryDevFileItems(
        in repositoriesURL: URL,
        fileManager: FileManager
    ) -> [BackupItem] {
        guard let repositories = try? fileManager.contentsOfDirectory(
            at: repositoriesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return repositories
            .filter { isGitRepository($0, fileManager: fileManager) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { repositoryURL in
                let repoKey = repositoryKey(for: repositoryURL, fileManager: fileManager)
                return BackupItem(
                    id: "git-repo-dev-\(repoKey.replacingOccurrences(of: "/", with: "-"))",
                    displayName: "Local repo dev files: \(repositoryURL.lastPathComponent)",
                    sourcePath: repositoryURL.path,
                    destinationPath: "Git Repos/\(repoKey)",
                    defaultEnabled: false,
                    syncsRepositoryDevFiles: true
                )
            }
    }

    private static func isGitRepository(_ url: URL, fileManager: FileManager) -> Bool {
        let dotGitURL = url.appendingPathComponent(".git")
        return fileManager.fileExists(atPath: dotGitURL.path)
    }

    private static func repositoryKey(for repositoryURL: URL, fileManager: FileManager) -> String {
        if let originURL = originRemoteURL(for: repositoryURL, fileManager: fileManager),
           let normalizedOrigin = normalizedOriginKey(originURL) {
            return normalizedOrigin
        }

        return "local/\(safePathComponent(repositoryURL.lastPathComponent))"
    }

    private static func originRemoteURL(for repositoryURL: URL, fileManager: FileManager) -> String? {
        let configURL = repositoryURL.appendingPathComponent(".git/config")
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        var inOrigin = false
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == "[remote \"origin\"]"
                continue
            }

            guard inOrigin, line.hasPrefix("url") else {
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, !parts[1].isEmpty {
                return parts[1]
            }
        }

        return nil
    }

    private static func normalizedOriginKey(_ originURL: String) -> String? {
        let trimmed = originURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutGit = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed

        if withoutGit.hasPrefix("git@") {
            let withoutPrefix = withoutGit.dropFirst(4)
            let parts = withoutPrefix.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                return nil
            }
            return "\(safePathComponent(String(parts[0])))/\(safeRelativePath(String(parts[1])))"
        }

        if let url = URL(string: withoutGit), let host = url.host {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else {
                return nil
            }
            return "\(safePathComponent(host))/\(safeRelativePath(path))"
        }

        return nil
    }

    private static func safeRelativePath(_ path: String) -> String {
        path
            .split(separator: "/")
            .map { safePathComponent(String($0)) }
            .joined(separator: "/")
    }

    private static func safePathComponent(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(component.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
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
