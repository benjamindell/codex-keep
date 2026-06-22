import Foundation
import Testing
@testable import CodexKeepCore

@Test func defaultBackupItemsStaySelective() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
    let socialPresence = codexHome.appendingPathComponent("social-presence", isDirectory: true)
    let cache = codexHome.appendingPathComponent("cache", isDirectory: true)

    try fileManager.createDirectory(at: socialPresence, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
    try "memory".write(
        to: socialPresence.appendingPathComponent("voice-preference-memory.md"),
        atomically: true,
        encoding: .utf8
    )
    try "cache".write(
        to: cache.appendingPathComponent("debug.md"),
        atomically: true,
        encoding: .utf8
    )

    let itemPaths = DefaultBackupItems.items(homeDirectory: root).map(\.sourcePath)

    #expect(itemPaths.contains { $0.hasSuffix("/.codex/automations") })
    #expect(itemPaths.contains { $0.hasSuffix("/.codex/AGENTS.md") })
    #expect(itemPaths.contains { $0.hasSuffix("/.codex/config.toml") })
    #expect(itemPaths.contains { $0.hasSuffix("/.codex/social-presence") })
    #expect(!itemPaths.contains { $0.hasSuffix("/.codex/cache") })
    #expect(!itemPaths.contains { $0.hasSuffix("/.codex/auth.json") })
    #expect(!itemPaths.contains { $0.hasSuffix("/.codex/sessions") })
    #expect(!itemPaths.contains { $0.hasSuffix("/.codex/logs_2.sqlite") })
    #expect(itemPaths.contains { $0.hasSuffix("/.agents/skills") })
}

@Test func repositoryDevFilesAreOptInAndCopyOnlyLocalEnvFiles() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let repository = root.appending(relativePath: "Repositories/example-app")
    let destination = root.appendingPathComponent("Backup", isDirectory: true)
    try writeGitConfig(
        in: repository,
        originURL: "git@github.com:example/example-app.git",
        fileManager: fileManager
    )
    try "secret".write(to: repository.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "local".write(to: repository.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    try "example".write(to: repository.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
    try "fab".write(to: repository.appendingPathComponent("fabfile_local.py"), atomically: true, encoding: .utf8)
    try "settings".write(to: repository.appendingPathComponent("local_settings.py"), atomically: true, encoding: .utf8)
    try fileManager.createDirectory(at: repository.appendingPathComponent(".vscode", isDirectory: true), withIntermediateDirectories: true)
    try "{}".write(to: repository.appending(relativePath: ".vscode/settings.json"), atomically: true, encoding: .utf8)
    try "tmp".write(to: repository.appending(relativePath: ".vscode/settings.json.tmp"), atomically: true, encoding: .utf8)
    try fileManager.createDirectory(at: repository.appendingPathComponent(".build", isDirectory: true), withIntermediateDirectories: true)
    try "nested".write(to: repository.appending(relativePath: ".build/.env"), atomically: true, encoding: .utf8)

    let items = DefaultBackupItems.items(homeDirectory: root, fileManager: fileManager)
    let repoItem = try #require(items.first { $0.id == "git-repo-dev-github.com-example-example-app" })
    #expect(repoItem.displayName == "Local repo dev files: example-app")
    #expect(repoItem.defaultEnabled == false)

    let disabledSettings = BackupSettings(
        destinationRootPath: destination.path,
        enabledItemIDs: Set(items.filter(\.defaultEnabled).map(\.id))
    )
    let disabledResult = try BackupService(fileManager: fileManager).runBackup(
        settings: disabledSettings,
        items: items,
        now: Date(timeIntervalSince1970: 0)
    )
    #expect(!disabledResult.manifest.files.contains { $0.backupRelativePath.contains("Git Repos/") })

    let enabledSettings = BackupSettings(
        destinationRootPath: destination.path,
        enabledItemIDs: Set(items.filter(\.defaultEnabled).map(\.id)),
        syncRepositoryDevFiles: true
    )
    let enabledResult = try BackupService(fileManager: fileManager).runBackup(
        settings: enabledSettings,
        items: items,
        now: Date(timeIntervalSince1970: 1)
    )

    #expect(fileManager.fileExists(atPath: enabledResult.latestURL.appending(relativePath: "Git Repos/github.com/example/example-app/.env").path))
    #expect(fileManager.fileExists(atPath: enabledResult.latestURL.appending(relativePath: "Git Repos/github.com/example/example-app/.env.local").path))
    #expect(fileManager.fileExists(atPath: enabledResult.latestURL.appending(relativePath: "Git Repos/github.com/example/example-app/fabfile_local.py").path))
    #expect(fileManager.fileExists(atPath: enabledResult.latestURL.appending(relativePath: "Git Repos/github.com/example/example-app/local_settings.py").path))
    #expect(fileManager.fileExists(atPath: enabledResult.latestURL.appending(relativePath: "Git Repos/github.com/example/example-app/.vscode/settings.json").path))
    #expect(!fileManager.fileExists(atPath: enabledResult.latestURL.appending(relativePath: "Git Repos/github.com/example/example-app/.env.example").path))
    #expect(!fileManager.fileExists(atPath: enabledResult.latestURL.appending(relativePath: "Git Repos/github.com/example/example-app/.build/.env").path))
    #expect(!fileManager.fileExists(atPath: enabledResult.latestURL.appending(relativePath: "Git Repos/github.com/example/example-app/.vscode/settings.json.tmp").path))
    #expect(enabledResult.manifest.files.contains { $0.backupRelativePath == "Git Repos/github.com/example/example-app/.env" })
    #expect(enabledResult.manifest.files.contains { $0.backupRelativePath == "Git Repos/github.com/example/example-app/.env.local" })
    #expect(enabledResult.manifest.files.contains { $0.backupRelativePath == "Git Repos/github.com/example/example-app/fabfile_local.py" })
    #expect(enabledResult.manifest.files.contains { $0.backupRelativePath == "Git Repos/github.com/example/example-app/local_settings.py" })
    #expect(enabledResult.manifest.files.contains { $0.backupRelativePath == "Git Repos/github.com/example/example-app/.vscode/settings.json" })
}

@Test func backupCopiesOnlyEnabledItemsAndRespectsExclusions() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
    let agentsHome = root.appendingPathComponent(".agents", isDirectory: true)
    let automations = codexHome.appendingPathComponent("automations", isDirectory: true)
    let skills = codexHome.appendingPathComponent("skills", isDirectory: true)
    let socialPresence = codexHome.appendingPathComponent("social-presence", isDirectory: true)
    let systemSkill = skills.appendingPathComponent(".system", isDirectory: true)
    let customSkill = skills.appendingPathComponent("custom-skill", isDirectory: true)
    let customSkillNodeModules = customSkill.appendingPathComponent("node_modules/playwright-core", isDirectory: true)
    let agentSkill = agentsHome.appendingPathComponent("skills/marketing-skill", isDirectory: true)
    let destination = root.appendingPathComponent("Backup", isDirectory: true)

    try fileManager.createDirectory(at: automations, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: socialPresence, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: systemSkill, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: customSkill, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: customSkillNodeModules, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agentSkill, withIntermediateDirectories: true)

    try "automation".write(
        to: automations.appendingPathComponent("automation.toml"),
        atomically: true,
        encoding: .utf8
    )
    try "generated".write(
        to: automations.appendingPathComponent(".run-jitter-salt"),
        atomically: true,
        encoding: .utf8
    )
    try "keep".write(
        to: socialPresence.appendingPathComponent("social-log.md"),
        atomically: true,
        encoding: .utf8
    )
    try "do not copy".write(
        to: systemSkill.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
    try "copy me".write(
        to: customSkill.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
    try "finder metadata".write(
        to: customSkill.appendingPathComponent(".DS_Store"),
        atomically: true,
        encoding: .utf8
    )
    try "temporary write".write(
        to: customSkill.appendingPathComponent("memory.md.tmp"),
        atomically: true,
        encoding: .utf8
    )
    try "dependency".write(
        to: customSkillNodeModules.appendingPathComponent("cli.js"),
        atomically: true,
        encoding: .utf8
    )
    try "agent skill".write(
        to: agentSkill.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let settings = BackupSettings(
        destinationRootPath: destination.path,
        enabledItemIDs: ["codex-automations", "codex-skills", "agent-skills", "codex-markdown-social-presence"]
    )

    let result = try BackupService(fileManager: fileManager).runBackup(
        settings: settings,
        items: DefaultBackupItems.items(homeDirectory: root),
        now: Date(timeIntervalSince1970: 0)
    )

    let latest = result.latestURL
    let machineRoot = destination.appendingPathComponent(Machine.currentName(), isDirectory: true)
    let snapshot = machineRoot.appending(relativePath: "Snapshots/1970-01-01")

    #expect(fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/automations/automation.toml").path))
    #expect(!fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/automations/.run-jitter-salt").path))
    #expect(fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/social-presence/social-log.md").path))
    #expect(fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/skills/custom-skill/SKILL.md").path))
    #expect(!fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/skills/custom-skill/.DS_Store").path))
    #expect(!fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/skills/custom-skill/memory.md.tmp").path))
    #expect(!fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/skills/.system/SKILL.md").path))
    #expect(!fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/skills/custom-skill/node_modules/playwright-core/cli.js").path))
    #expect(fileManager.fileExists(atPath: latest.appending(relativePath: "Agents/skills/marketing-skill/SKILL.md").path))
    #expect(!fileManager.fileExists(atPath: latest.appending(relativePath: ".codex").path))
    #expect(fileManager.fileExists(atPath: latest.appendingPathComponent("manifest.json").path))
    #expect(fileManager.fileExists(atPath: latest.appendingPathComponent(PayloadArchive.fileName).path))
    #expect(fileManager.fileExists(atPath: snapshot.appending(relativePath: "Codex/automations/automation.toml").path))
    #expect(fileManager.fileExists(atPath: snapshot.appendingPathComponent(PayloadArchive.fileName).path))
    #expect(!result.manifest.files.contains { $0.backupRelativePath.hasSuffix(".DS_Store") })
    #expect(!result.manifest.files.contains { $0.backupRelativePath.hasSuffix(".tmp") })

    let extractedArchive = root.appendingPathComponent("Extracted", isDirectory: true)
    try PayloadArchive.extract(
        archiveURL: latest.appendingPathComponent(PayloadArchive.fileName),
        to: extractedArchive
    )
    #expect(fileManager.fileExists(atPath: extractedArchive.appending(relativePath: "Codex/skills/custom-skill/SKILL.md").path))
}

@Test func backupCopiesSymlinkedCodexSkillDirectoriesAsFolderContent() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let codexSkills = root.appending(relativePath: ".codex/skills")
    let agentsSkill = root.appending(relativePath: ".agents/skills/heysummit-intercom-article-audit")
    let symlinkedCodexSkill = codexSkills.appendingPathComponent("heysummit-intercom-article-audit")
    let destination = root.appendingPathComponent("Backup", isDirectory: true)

    try fileManager.createDirectory(at: codexSkills, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agentsSkill, withIntermediateDirectories: true)
    try "audit skill".write(
        to: agentsSkill.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
    try "notes".write(
        to: agentsSkill.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    try fileManager.createSymbolicLink(at: symlinkedCodexSkill, withDestinationURL: agentsSkill)

    let result = try BackupService(fileManager: fileManager).runBackup(
        settings: BackupSettings(destinationRootPath: destination.path, enabledItemIDs: ["codex-skills"]),
        items: DefaultBackupItems.items(homeDirectory: root, fileManager: fileManager),
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(fileManager.fileExists(atPath: result.latestURL.appending(relativePath: "Codex/skills/heysummit-intercom-article-audit/SKILL.md").path))
    #expect(fileManager.fileExists(atPath: result.latestURL.appending(relativePath: "Codex/skills/heysummit-intercom-article-audit/README.md").path))
    #expect(result.manifest.files.contains {
        $0.backupRelativePath == "Codex/skills/heysummit-intercom-article-audit/SKILL.md"
    })

    let extractedArchive = root.appendingPathComponent("Extracted", isDirectory: true)
    try PayloadArchive.extract(
        archiveURL: result.latestURL.appendingPathComponent(PayloadArchive.fileName),
        to: extractedArchive
    )
    #expect(fileManager.fileExists(atPath: extractedArchive.appending(relativePath: "Codex/skills/heysummit-intercom-article-audit/SKILL.md").path))
}

@Test func backupRefreshesStableLatestFolderAndRemovesStaleFiles() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
    let automations = codexHome.appendingPathComponent("automations", isDirectory: true)
    let destination = root.appendingPathComponent("Backup", isDirectory: true)

    try fileManager.createDirectory(at: automations, withIntermediateDirectories: true)
    try "first".write(
        to: automations.appendingPathComponent("automation.toml"),
        atomically: true,
        encoding: .utf8
    )

    let settings = BackupSettings(
        destinationRootPath: destination.path,
        enabledItemIDs: ["codex-automations"]
    )
    let service = BackupService(fileManager: fileManager)
    let firstResult = try service.runBackup(
        settings: settings,
        items: DefaultBackupItems.items(homeDirectory: root),
        now: Date(timeIntervalSince1970: 0)
    )

    let latest = firstResult.latestURL
    let staleFile = latest.appending(relativePath: "Codex/automations/stale.toml")
    let duplicateCodex = latest.appendingPathComponent("Codex 2", isDirectory: true)
    let duplicateLatest = destination
        .appendingPathComponent(Machine.currentName(), isDirectory: true)
        .appendingPathComponent("latest 2", isDirectory: true)

    try "stale".write(to: staleFile, atomically: true, encoding: .utf8)
    try fileManager.createDirectory(at: duplicateCodex, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: duplicateLatest, withIntermediateDirectories: true)

    try "second".write(
        to: automations.appendingPathComponent("automation.toml"),
        atomically: true,
        encoding: .utf8
    )

    let secondResult = try service.runBackup(
        settings: settings,
        items: DefaultBackupItems.items(homeDirectory: root),
        now: Date(timeIntervalSince1970: 1)
    )

    #expect(secondResult.latestURL == firstResult.latestURL)
    #expect(fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/automations/automation.toml").path))
    #expect(!fileManager.fileExists(atPath: staleFile.path))
    #expect(!fileManager.fileExists(atPath: duplicateCodex.path))
    #expect(!fileManager.fileExists(atPath: duplicateLatest.path))
}

@Test func backupKeepsSevenDailySnapshots() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
    let automations = codexHome.appendingPathComponent("automations", isDirectory: true)
    let destination = root.appendingPathComponent("Backup", isDirectory: true)

    try fileManager.createDirectory(at: automations, withIntermediateDirectories: true)

    let settings = BackupSettings(
        destinationRootPath: destination.path,
        enabledItemIDs: ["codex-automations"]
    )
    let service = BackupService(fileManager: fileManager)

    for dayOffset in 0..<8 {
        try "day \(dayOffset)".write(
            to: automations.appendingPathComponent("automation.toml"),
            atomically: true,
            encoding: .utf8
        )

        _ = try service.runBackup(
            settings: settings,
            items: DefaultBackupItems.items(homeDirectory: root),
            now: Date(timeIntervalSince1970: TimeInterval(dayOffset * 86_400))
        )
    }

    let snapshotsURL = destination
        .appendingPathComponent(Machine.currentName(), isDirectory: true)
        .appendingPathComponent("Snapshots", isDirectory: true)
    let snapshotNames = try fileManager.contentsOfDirectory(atPath: snapshotsURL.path).sorted()

    #expect(snapshotNames == [
        "1970-01-02",
        "1970-01-03",
        "1970-01-04",
        "1970-01-05",
        "1970-01-06",
        "1970-01-07",
        "1970-01-08"
    ])
    #expect(fileManager.fileExists(atPath: snapshotsURL.appending(relativePath: "1970-01-08/Codex/automations/automation.toml").path))
}

@Test func settingsStoreEnablesNewDefaultItemsForExistingSettings() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
    let socialPresence = codexHome.appendingPathComponent("social-presence", isDirectory: true)
    let repository = root.appending(relativePath: "Repositories/example-app")
    let settingsURL = root.appending(relativePath: "Application Support/Codex Keep/settings.json")

    try fileManager.createDirectory(at: socialPresence, withIntermediateDirectories: true)
    try writeGitConfig(
        in: repository,
        originURL: "git@github.com:example/example-app.git",
        fileManager: fileManager
    )
    try "keep".write(
        to: socialPresence.appendingPathComponent("social-log.md"),
        atomically: true,
        encoding: .utf8
    )
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let previousSettings = BackupSettings(
        destinationRootPath: root.appendingPathComponent("Backup", isDirectory: true).path,
        enabledItemIDs: ["codex-automations"]
    )
    let encoder = JSONEncoder()
    try encoder.encode(previousSettings).write(to: settingsURL)

    let store = SettingsStore(
        fileManager: fileManager,
        settingsURL: settingsURL,
        homeDirectory: root
    )

    #expect(store.settings.enabledItemIDs.contains("codex-automations"))
    #expect(store.settings.enabledItemIDs.contains("codex-markdown-social-presence"))
    #expect(!store.settings.enabledItemIDs.contains("git-repo-dev-github.com-example-example-app"))
    #expect(store.settings.syncRepositoryDevFiles == false)
}

private func writeGitConfig(in repository: URL, originURL: String, fileManager: FileManager) throws {
    let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try """
    [remote "origin"]
        url = \(originURL)
    """.write(to: gitDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
}

private extension URL {
    func appending(relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }
}
