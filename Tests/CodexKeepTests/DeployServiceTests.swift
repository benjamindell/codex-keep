import Foundation
import Testing
@testable import CodexKeepCore

@Test func deployPlanExpandsAutomationsAndDetectsChanges() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let backup = root.appending(relativePath: "Backup/Mac/latest")
    let backupDaily = backup.appending(relativePath: "Codex/automations/daily-report")
    let backupWeekly = backup.appending(relativePath: "Codex/automations/weekly-review")
    let localDaily = home.appending(relativePath: ".codex/automations/daily-report")
    let localConfig = home.appending(relativePath: ".codex/config.toml")

    try fileManager.createDirectory(at: backupDaily, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: backupWeekly, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: localDaily, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: localConfig.deletingLastPathComponent(), withIntermediateDirectories: true)

    try "new daily".write(to: backupDaily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "new weekly".write(to: backupWeekly.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "old daily".write(to: localDaily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "same config".write(to: backup.appending(relativePath: "Codex/config.toml"), atomically: true, encoding: .utf8)
    try "same config".write(to: localConfig, atomically: true, encoding: .utf8)
    try writeManifest(to: backup)

    let plan = try DeployService(fileManager: fileManager).makePlan(sourceURL: backup, homeDirectory: home)

    let daily = try #require(plan.items.first { $0.id == "codex-automations/daily-report" })
    let weekly = try #require(plan.items.first { $0.id == "codex-automations/weekly-review" })
    let config = try #require(plan.items.first { $0.id == "codex-config" })

    #expect(daily.status == .changed)
    #expect(daily.isAutomation)
    #expect(weekly.status == .new)
    #expect(config.status == .unchanged)
}

@Test func deploySelectedItemsCreatesSafetySnapshotBeforeReplacingLocalFiles() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let backup = root.appending(relativePath: "Backup/Mac/latest")
    let backupDaily = backup.appending(relativePath: "Codex/automations/daily-report")
    let backupWeekly = backup.appending(relativePath: "Codex/automations/weekly-review")
    let localDaily = home.appending(relativePath: ".codex/automations/daily-report")
    let localWeekly = home.appending(relativePath: ".codex/automations/weekly-review")
    let destinationRoot = root.appendingPathComponent("Codex Keep", isDirectory: true)

    try fileManager.createDirectory(at: backupDaily, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: backupWeekly, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: localDaily, withIntermediateDirectories: true)

    try "new daily".write(to: backupDaily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "new weekly".write(to: backupWeekly.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "old daily".write(to: localDaily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try writeManifest(to: backup)

    let service = DeployService(fileManager: fileManager)
    let plan = try service.makePlan(sourceURL: backup, homeDirectory: home)
    let result = try service.deploy(
        plan: plan,
        selectedItemIDs: ["codex-automations/daily-report"],
        settings: BackupSettings(destinationRootPath: destinationRoot.path, enabledItemIDs: []),
        now: Date(timeIntervalSince1970: 0)
    )

    let deployedDaily = try String(contentsOf: localDaily.appendingPathComponent("automation.toml"), encoding: .utf8)
    #expect(deployedDaily == "new daily")
    #expect(!fileManager.fileExists(atPath: localWeekly.path))
    #expect(fileManager.fileExists(atPath: result.safetySnapshotURL.appendingPathComponent("manifest.json").path))
    #expect(try safetySnapshotContains("old daily", in: result.safetySnapshotURL, fileManager: fileManager))
}

@Test func deployRestoresOnlyAutomationsListedInMoveSafetySnapshot() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let snapshot = root.appending(relativePath: "Backup/Mac/Automation Move Safety/snapshot")
    let movedAutomation = snapshot.appending(relativePath: "Codex/automations/moved")
    let otherAutomation = snapshot.appending(relativePath: "Codex/automations/not-listed")
    try fileManager.createDirectory(at: movedAutomation, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: otherAutomation, withIntermediateDirectories: true)
    try "moved".write(to: movedAutomation.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "other".write(to: otherAutomation.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)

    let manifest = BackupManifest(
        appName: "Codex Keep Automation Move Safety",
        schemaVersion: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        machineName: "Mac",
        items: [BackupManifestItem(
            id: "codex-automations/moved",
            displayName: "Automation: moved",
            sourcePath: "/old-home/.codex/automations/moved",
            destinationPath: movedAutomation.path,
            status: .copied,
            fileCount: 1,
            byteCount: 5,
            message: nil
        )],
        warnings: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: snapshot.appendingPathComponent("manifest.json"))

    let service = DeployService(fileManager: fileManager)
    let plan = try service.makePlan(sourceURL: snapshot, homeDirectory: home)
    #expect(plan.items.map(\.id) == ["codex-automations/moved"])

    let result = try service.deploy(
        plan: plan,
        selectedItemIDs: ["codex-automations/moved"],
        settings: BackupSettings(destinationRootPath: root.appendingPathComponent("Codex Keep").path, enabledItemIDs: []),
        now: Date(timeIntervalSince1970: 0)
    )
    #expect(result.deployedItemCount == 1)
    #expect(try String(contentsOf: home.appending(relativePath: ".codex/automations/moved/automation.toml"), encoding: .utf8) == "moved")
    #expect(!fileManager.fileExists(atPath: home.appending(relativePath: ".codex/automations/not-listed").path))
}

@Test func deployKeepsLocalAutomationWhenMoveSafetySnapshotIsIncomplete() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let snapshot = root.appending(relativePath: "Backup/Mac/Automation Move Safety/snapshot")
    let backupAutomation = snapshot.appending(relativePath: "Codex/automations/daily-report")
    let localAutomation = home.appending(relativePath: ".codex/automations/daily-report")
    try fileManager.createDirectory(at: backupAutomation, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: localAutomation, withIntermediateDirectories: true)
    try "new".write(to: backupAutomation.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "old".write(to: localAutomation.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)

    let manifest = BackupManifest(
        appName: "Codex Keep Automation Move Safety",
        schemaVersion: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        machineName: "Mac",
        items: [BackupManifestItem(
            id: "codex-automations/daily-report",
            displayName: "Automation: daily-report",
            sourcePath: "/old-home/.codex/automations/daily-report",
            destinationPath: backupAutomation.path,
            status: .copied,
            fileCount: 2,
            byteCount: 6,
            message: nil
        )],
        warnings: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: snapshot.appendingPathComponent("manifest.json"))

    let service = DeployService(fileManager: fileManager)
    let plan = try service.makePlan(sourceURL: snapshot, homeDirectory: home)
    #expect(throws: DeployServiceError.self) {
        try service.deploy(
            plan: plan,
            selectedItemIDs: ["codex-automations/daily-report"],
            settings: BackupSettings(destinationRootPath: root.appendingPathComponent("Codex Keep").path, enabledItemIDs: [])
        )
    }
    #expect(try String(contentsOf: localAutomation.appendingPathComponent("automation.toml"), encoding: .utf8) == "old")
}

private func writeManifest(to backupURL: URL) throws {
    let manifest = BackupManifest(
        appName: "Codex Keep",
        schemaVersion: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        machineName: "Mac",
        items: [
            BackupManifestItem(
                id: "codex-automations",
                displayName: "Codex automations",
                sourcePath: "/source/.codex/automations",
                destinationPath: "/staging/Codex/automations",
                status: .copied,
                fileCount: 2,
                byteCount: 20,
                message: nil
            ),
            BackupManifestItem(
                id: "codex-config",
                displayName: "Codex config",
                sourcePath: "/source/.codex/config.toml",
                destinationPath: "/staging/Codex/config.toml",
                status: .copied,
                fileCount: 1,
                byteCount: 11,
                message: nil
            )
        ],
        warnings: []
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: backupURL.appendingPathComponent("manifest.json"), options: .atomic)
}

private func safetySnapshotContains(
    _ expected: String,
    in snapshotURL: URL,
    fileManager: FileManager
) throws -> Bool {
    guard let enumerator = fileManager.enumerator(
        at: snapshotURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else {
        return false
    }

    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            continue
        }

        if (try? String(contentsOf: url, encoding: .utf8)) == expected {
            return true
        }
    }

    return false
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
