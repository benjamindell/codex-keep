import Foundation
import Testing
@testable import CodexKeepCore

@Test func defaultBackupItemsStaySelective() {
    let itemPaths = DefaultBackupItems.items().map(\.sourcePath)

    #expect(itemPaths.contains { $0.hasSuffix("/.codex/automations") })
    #expect(itemPaths.contains { $0.hasSuffix("/.codex/AGENTS.md") })
    #expect(itemPaths.contains { $0.hasSuffix("/.codex/config.toml") })
    #expect(!itemPaths.contains { $0.hasSuffix("/.codex/auth.json") })
    #expect(!itemPaths.contains { $0.hasSuffix("/.codex/sessions") })
    #expect(!itemPaths.contains { $0.hasSuffix("/.codex/logs_2.sqlite") })
    #expect(itemPaths.contains { $0.hasSuffix("/.agents/skills") })
}

@Test func backupCopiesOnlyEnabledItemsAndRespectsExclusions() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
    let agentsHome = root.appendingPathComponent(".agents", isDirectory: true)
    let automations = codexHome.appendingPathComponent("automations", isDirectory: true)
    let skills = codexHome.appendingPathComponent("skills", isDirectory: true)
    let systemSkill = skills.appendingPathComponent(".system", isDirectory: true)
    let customSkill = skills.appendingPathComponent("custom-skill", isDirectory: true)
    let agentSkill = agentsHome.appendingPathComponent("skills/marketing-skill", isDirectory: true)
    let destination = root.appendingPathComponent("Backup", isDirectory: true)

    try fileManager.createDirectory(at: automations, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: systemSkill, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: customSkill, withIntermediateDirectories: true)
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
    try "agent skill".write(
        to: agentSkill.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let settings = BackupSettings(
        destinationRootPath: destination.path,
        enabledItemIDs: ["codex-automations", "codex-skills", "agent-skills"]
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
    #expect(fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/skills/custom-skill/SKILL.md").path))
    #expect(!fileManager.fileExists(atPath: latest.appending(relativePath: "Codex/skills/.system/SKILL.md").path))
    #expect(fileManager.fileExists(atPath: latest.appending(relativePath: "Agents/skills/marketing-skill/SKILL.md").path))
    #expect(!fileManager.fileExists(atPath: latest.appending(relativePath: ".codex").path))
    #expect(fileManager.fileExists(atPath: latest.appendingPathComponent("manifest.json").path))
    #expect(fileManager.fileExists(atPath: snapshot.appending(relativePath: "Codex/automations/automation.toml").path))
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

private extension URL {
    func appending(relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }
}
