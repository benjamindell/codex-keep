import Foundation
import Testing
@testable import CodexKeepCore

@Test func automationMoveCreatesPendingMoveAndDeletesLocalCopy() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let destinationRoot = root.appendingPathComponent("Codex Keep", isDirectory: true)
    let daily = home.appending(relativePath: ".codex/automations/daily-report")
    let weekly = home.appending(relativePath: ".codex/automations/weekly-review")

    try fileManager.createDirectory(at: daily, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: weekly, withIntermediateDirectories: true)
    try "daily".write(to: daily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "weekly".write(to: weekly.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)

    let service = AutomationMoveService(fileManager: fileManager)
    let result = try service.moveAutomations(
        ids: ["daily-report"],
        to: "Mac-Mini",
        settings: BackupSettings(destinationRootPath: destinationRoot.path, enabledItemIDs: []),
        homeDirectory: home,
        now: Date(timeIntervalSince1970: 0),
        moveID: "move-1"
    )

    #expect(result.movedCount == 1)
    #expect(!fileManager.fileExists(atPath: daily.path))
    #expect(fileManager.fileExists(atPath: weekly.path))

    let movedAutomation = destinationRoot.appending(relativePath: "Mac-Mini/Automation Moves/move-1/Automations/daily-report/automation.toml")
    let unmovedAutomation = destinationRoot.appending(relativePath: "Mac-Mini/Automation Moves/move-1/Automations/weekly-review/automation.toml")
    #expect(try String(contentsOf: movedAutomation, encoding: .utf8) == "daily")
    #expect(!fileManager.fileExists(atPath: unmovedAutomation.path))

    let manifestData = try Data(contentsOf: result.moveURL.appendingPathComponent("manifest.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(AutomationMoveManifest.self, from: manifestData)
    #expect(manifest.targetMachineName == "Mac-Mini")
    #expect(manifest.automations.map(\.id) == ["daily-report"])
    #expect(try snapshotContains("daily", in: result.safetySnapshotURL, fileManager: fileManager))
}

@Test func automationMoveConsumeInstallsPendingMovesAndRemovesMovePackage() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let destinationRoot = root.appendingPathComponent("Codex Keep", isDirectory: true)
    let localDaily = home.appending(relativePath: ".codex/automations/daily-report")
    let moveDaily = destinationRoot.appending(relativePath: "\(Machine.currentName())/Automation Moves/move-1/Automations/daily-report")
    let moveURL = destinationRoot.appending(relativePath: "\(Machine.currentName())/Automation Moves/move-1")

    try fileManager.createDirectory(at: localDaily, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: moveDaily, withIntermediateDirectories: true)
    try "old".write(to: localDaily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "new".write(to: moveDaily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try writeMoveManifest(to: moveURL, targetMachineName: Machine.currentName())

    let service = AutomationMoveService(fileManager: fileManager)
    let result = try service.consumePendingMoves(
        settings: BackupSettings(destinationRootPath: destinationRoot.path, enabledItemIDs: []),
        homeDirectory: home,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.installedCount == 1)
    #expect(result.consumedMoveCount == 1)
    #expect(!fileManager.fileExists(atPath: moveURL.path))
    #expect(try String(contentsOf: localDaily.appendingPathComponent("automation.toml"), encoding: .utf8) == "new")
    let safetySnapshotURL = try #require(result.safetySnapshotURL)
    #expect(try snapshotContains("old", in: safetySnapshotURL, fileManager: fileManager))
}

@Test func automationMoveConsumeIgnoresAutomationFoldersNotListedInManifest() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let destinationRoot = root.appendingPathComponent("Codex Keep", isDirectory: true)
    let moveDaily = destinationRoot.appending(relativePath: "\(Machine.currentName())/Automation Moves/move-1/Automations/daily-report")
    let moveWeekly = destinationRoot.appending(relativePath: "\(Machine.currentName())/Automation Moves/move-1/Automations/weekly-review")
    let moveURL = destinationRoot.appending(relativePath: "\(Machine.currentName())/Automation Moves/move-1")
    let localDaily = home.appending(relativePath: ".codex/automations/daily-report")
    let localWeekly = home.appending(relativePath: ".codex/automations/weekly-review")

    try fileManager.createDirectory(at: moveDaily, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: moveWeekly, withIntermediateDirectories: true)
    try "daily".write(to: moveDaily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try "weekly".write(to: moveWeekly.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try writeMoveManifest(to: moveURL, targetMachineName: Machine.currentName())

    let service = AutomationMoveService(fileManager: fileManager)
    let result = try service.consumePendingMoves(
        settings: BackupSettings(destinationRootPath: destinationRoot.path, enabledItemIDs: []),
        homeDirectory: home,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.installedCount == 1)
    #expect(try String(contentsOf: localDaily.appendingPathComponent("automation.toml"), encoding: .utf8) == "daily")
    #expect(!fileManager.fileExists(atPath: localWeekly.path))
}

@Test func automationMoveListsPendingMovesWithoutInstallingThem() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let destinationRoot = root.appendingPathComponent("Codex Keep", isDirectory: true)
    let moveDaily = destinationRoot.appending(relativePath: "\(Machine.currentName())/Automation Moves/move-1/Automations/daily-report")
    let moveURL = destinationRoot.appending(relativePath: "\(Machine.currentName())/Automation Moves/move-1")
    let localDaily = home.appending(relativePath: ".codex/automations/daily-report")

    try fileManager.createDirectory(at: moveDaily, withIntermediateDirectories: true)
    try "new".write(to: moveDaily.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    try writeMoveManifest(to: moveURL, targetMachineName: Machine.currentName())

    let service = AutomationMoveService(fileManager: fileManager)
    let moves = try service.pendingMoves(
        settings: BackupSettings(destinationRootPath: destinationRoot.path, enabledItemIDs: [])
    )

    let move = try #require(moves.first)
    #expect(moves.count == 1)
    #expect(move.automationIDs == ["daily-report"])
    #expect(move.sourceMachineName == "Source-Mac")
    #expect(fileManager.fileExists(atPath: moveURL.path))
    #expect(!fileManager.fileExists(atPath: localDaily.path))
}

private func writeMoveManifest(to moveURL: URL, targetMachineName: String) throws {
    let manifest = AutomationMoveManifest(
        createdAt: Date(timeIntervalSince1970: 0),
        sourceMachineName: "Source-Mac",
        targetMachineName: targetMachineName,
        automations: [
            AutomationMoveManifestItem(id: "daily-report", fileCount: 1, byteCount: 3)
        ]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: moveURL.appendingPathComponent("manifest.json"), options: .atomic)
}

private func snapshotContains(
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
