import Foundation
import Testing
@testable import CodexKeepCore

@Test func backupRetentionKeepsSevenDaysAndAtLeastTwentySafetySnapshots() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let snapshotsURL = root.appendingPathComponent("Sync Safety", isDirectory: true)
    let now = try #require(retentionDateFormatter.date(from: "2026-08-25-120000"))
    try fileManager.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)

    var oldestURL: URL?
    for index in 0..<125 {
        let date = now.addingTimeInterval(-8 * 24 * 60 * 60 - TimeInterval(index + 1))
        let url = snapshotsURL.appendingPathComponent(retentionDateFormatter.string(from: date), isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        oldestURL = url
    }

    let exactCutoff = now.addingTimeInterval(-BackupRetentionPolicy.safetySnapshotRetentionInterval)
    let exactCutoffURL = snapshotsURL.appendingPathComponent(
        retentionDateFormatter.string(from: exactCutoff),
        isDirectory: true
    )
    try fileManager.createDirectory(at: exactCutoffURL, withIntermediateDirectories: true)

    for index in 1...5 {
        let date = now.addingTimeInterval(-TimeInterval(index * 60 * 60))
        try fileManager.createDirectory(
            at: snapshotsURL.appendingPathComponent(retentionDateFormatter.string(from: date), isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    try BackupRetentionPolicy.pruneSafetySnapshots(
        in: snapshotsURL,
        fileManager: fileManager,
        now: now
    )

    #expect(try fileManager.contentsOfDirectory(atPath: snapshotsURL.path).count == 31)
    #expect(fileManager.fileExists(atPath: exactCutoffURL.path))
    #expect(!fileManager.fileExists(atPath: try #require(oldestURL).path))

    try BackupRetentionPolicy.pruneSafetySnapshots(
        in: snapshotsURL,
        fileManager: fileManager,
        now: now
    )

    #expect(try fileManager.contentsOfDirectory(atPath: snapshotsURL.path).count == 20)
    #expect(fileManager.fileExists(atPath: exactCutoffURL.path))
}

@Test func backupRetentionRemovesOnlyExpiredManagedWorkingData() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let now = try #require(retentionDateFormatter.date(from: "2026-08-25-120000"))
    let oldDate = now.addingTimeInterval(-BackupRetentionPolicy.staleWorkingItemAge - 1)
    let oldMoveDate = now.addingTimeInterval(-BackupRetentionPolicy.incompleteAutomationMoveAge - 1)
    let exactCutoff = now.addingTimeInterval(-BackupRetentionPolicy.staleWorkingItemAge)
    let recentDate = now.addingTimeInterval(-60)
    let snapshotsURL = root.appendingPathComponent("Snapshots", isDirectory: true)
    let generationsURL = SyncGenerationLayout.generationsURL(in: root)
    let movesURL = root.appendingPathComponent("Automation Moves", isDirectory: true)
    try fileManager.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: generationsURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: movesURL, withIntermediateDirectories: true)

    let oldStaging = root.appendingPathComponent(".staging-old", isDirectory: true)
    let exactStaging = root.appendingPathComponent(".staging-exact", isDirectory: true)
    let recentStaging = root.appendingPathComponent(".staging-recent", isDirectory: true)
    let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
    let oldSnapshotPublish = snapshotsURL.appendingPathComponent(".2026-08-01-publish-old", isDirectory: true)
    let oldGenerationPublish = generationsURL.appendingPathComponent(".publish-old.json")
    let oldMoveArchive = movesURL.appendingPathComponent(".automation-move-old.zip")
    let incompleteOldMove = movesURL.appendingPathComponent("incomplete-old", isDirectory: true)
    let incompleteRecentMove = movesURL.appendingPathComponent("incomplete-recent", isDirectory: true)
    let completeOldMove = movesURL.appendingPathComponent("complete-old", isDirectory: true)

    for url in [oldStaging, exactStaging, recentStaging, unrelated, oldSnapshotPublish, incompleteOldMove, incompleteRecentMove, completeOldMove] {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try Data().write(to: oldGenerationPublish)
    try Data().write(to: oldMoveArchive)
    try "{}".write(
        to: completeOldMove.appendingPathComponent("manifest.json"),
        atomically: true,
        encoding: .utf8
    )

    for url in [oldStaging, unrelated, oldSnapshotPublish, oldGenerationPublish, oldMoveArchive] {
        try setModificationDate(oldDate, for: url, fileManager: fileManager)
    }
    for url in [incompleteOldMove, completeOldMove] {
        try setModificationDate(oldMoveDate, for: url, fileManager: fileManager)
    }
    try setModificationDate(exactCutoff, for: exactStaging, fileManager: fileManager)
    try setModificationDate(recentDate, for: recentStaging, fileManager: fileManager)
    try setModificationDate(recentDate, for: incompleteRecentMove, fileManager: fileManager)

    try BackupRetentionPolicy.pruneMachineRoot(root, fileManager: fileManager, now: now)

    #expect(!fileManager.fileExists(atPath: oldStaging.path))
    #expect(!fileManager.fileExists(atPath: oldSnapshotPublish.path))
    #expect(!fileManager.fileExists(atPath: oldGenerationPublish.path))
    #expect(!fileManager.fileExists(atPath: oldMoveArchive.path))
    #expect(!fileManager.fileExists(atPath: incompleteOldMove.path))
    #expect(fileManager.fileExists(atPath: exactStaging.path))
    #expect(fileManager.fileExists(atPath: recentStaging.path))
    #expect(fileManager.fileExists(atPath: unrelated.path))
    #expect(fileManager.fileExists(atPath: incompleteRecentMove.path))
    #expect(fileManager.fileExists(atPath: completeOldMove.path))
}

@Test func backupRetentionKeepsAllSafetySnapshotsFromTheLastSevenDays() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let snapshotsURL = root.appendingPathComponent("Sync Safety", isDirectory: true)
    let now = try #require(retentionDateFormatter.date(from: "2026-08-25-120000"))
    try fileManager.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
    for index in 1...25 {
        let date = now.addingTimeInterval(-TimeInterval(index * 60))
        try fileManager.createDirectory(
            at: snapshotsURL.appendingPathComponent(retentionDateFormatter.string(from: date), isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    try BackupRetentionPolicy.pruneSafetySnapshots(
        in: snapshotsURL,
        fileManager: fileManager,
        now: now
    )

    #expect(try fileManager.contentsOfDirectory(atPath: snapshotsURL.path).count == 25)
}

@Test func backupRunAppliesRetentionHousekeeping() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let sourceURL = root.appending(relativePath: "Home/.codex/automations/automation.toml")
    let destination = root.appendingPathComponent("Backup", isDirectory: true)
    let machineRoot = destination.appendingPathComponent(Machine.currentName(), isDirectory: true)
    let oldStaging = machineRoot.appendingPathComponent(".staging-interrupted", isDirectory: true)
    let now = Date(timeIntervalSince1970: 2 * 24 * 60 * 60)
    try fileManager.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: oldStaging, withIntermediateDirectories: true)
    try "automation".write(to: sourceURL, atomically: true, encoding: .utf8)
    try setModificationDate(
        now.addingTimeInterval(-BackupRetentionPolicy.staleWorkingItemAge - 1),
        for: oldStaging,
        fileManager: fileManager
    )

    _ = try BackupService(fileManager: fileManager).runBackup(
        settings: BackupSettings(
            destinationRootPath: destination.path,
            enabledItemIDs: ["codex-automations"]
        ),
        items: [
            BackupItem(
                id: "codex-automations",
                displayName: "Codex automations",
                sourcePath: sourceURL.deletingLastPathComponent().path,
                destinationPath: "Codex/automations"
            )
        ],
        now: now
    )

    #expect(!fileManager.fileExists(atPath: oldStaging.path))
}

private func setModificationDate(_ date: Date, for url: URL, fileManager: FileManager) throws {
    try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private let retentionDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter
}()

private extension URL {
    func appending(relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }
}
