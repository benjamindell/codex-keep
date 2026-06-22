import CryptoKit
import Foundation
import Testing
@testable import CodexKeepCore

@Test func peerSyncPlansFileLevelChangesAndReviewItems() throws {
    let fixture = try PeerSyncFixture()
    defer { fixture.cleanUp() }

    let plans = try fixture.makePlans()
    let items = Dictionary(uniqueKeysWithValues: plans.flatMap(\.items).map { ($0.backupRelativePath, $0) })

    #expect(items["Codex/skills/shared/SKILL.md"]?.status == .incomingChanged)
    #expect(items["Codex/skills/new/SKILL.md"]?.status == .incomingNew)
    #expect(items["Codex/skills/conflict/SKILL.md"]?.status == .conflict)
    #expect(items["Codex/skills/local-only/SKILL.md"]?.status == .localChanged)
    #expect(items["Codex/skills/deleted/SKILL.md"]?.status == .peerDeletedReviewRequired)
    #expect(items["Codex/skills/shared/.DS_Store"] == nil)
    #expect(items["Codex/skills/shared/memory.md.tmp"] == nil)
}

@Test func peerSyncAppliesSafeChangesCopiesConflictsAndSnapshotsDeletes() throws {
    let fixture = try PeerSyncFixture()
    defer { fixture.cleanUp() }

    let plans = try fixture.makePlans()
    let selectedIDs = Set(plans.flatMap(\.items).compactMap { item in
        switch item.status {
        case .incomingNew, .incomingChanged, .conflict, .peerDeletedReviewRequired:
            return item.id
        case .unchanged, .localChanged:
            return nil
        }
    })

    let result = try PeerSyncService(fileManager: fixture.fileManager).apply(
        plans: plans,
        selectedItemIDs: selectedIDs,
        settings: fixture.settings,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/skills/shared/SKILL.md"), encoding: .utf8) == "peer update")
    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/skills/new/SKILL.md"), encoding: .utf8) == "peer new")
    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/skills/conflict/SKILL.md"), encoding: .utf8) == "local conflict")
    #expect(!fixture.fileManager.fileExists(atPath: fixture.home.appending(relativePath: ".codex/skills/deleted/SKILL.md").path))
    #expect(fixture.fileManager.fileExists(atPath: fixture.home.appending(relativePath: ".codex/skills/conflict/SKILL.conflict-Peer-Mac-19700101-010000.md").path))
    #expect(fixture.fileManager.fileExists(atPath: result.safetySnapshotURL.appendingPathComponent("manifest.json").path))
    #expect(result.updatedSettings.syncStates["Codex/skills/shared/SKILL.md"]?.sha256 == sha256("peer update"))
    #expect(result.updatedSettings.syncStates["Codex/skills/deleted/SKILL.md"]?.sha256 == nil)
    #expect(result.updatedSettings.syncTombstones["Codex/skills/deleted/SKILL.md"] != nil)
}

@Test func peerDiscoveryShowsVisibleMachineFoldersBeforeManifestHydrates() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let peerLatest = root.appending(relativePath: "Ben-s-Mac-Mini/latest")
    try fileManager.createDirectory(at: peerLatest, withIntermediateDirectories: true)

    let settings = BackupSettings(
        destinationRootPath: root.path,
        enabledItemIDs: []
    )

    #expect(PeerSyncService(fileManager: fileManager).availablePeerMachineNames(settings: settings) == ["Ben-s-Mac-Mini"])
}

private final class PeerSyncFixture {
    let fileManager = FileManager.default
    let root: URL
    let home: URL
    let destination: URL
    let peerLatest: URL
    var settings: BackupSettings!
    var localManifest: BackupManifest!

    init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        destination = root.appendingPathComponent("Codex Keep", isDirectory: true)
        peerLatest = destination.appending(relativePath: "Peer-Mac/latest")

        try writeLocalSkill("shared", content: "local base")
        try writeLocalSkill("conflict", content: "local conflict")
        try writeLocalSkill("local-only", content: "local change")
        try writeLocalSkill("deleted", content: "delete me")
        try writePeerSkill("shared", content: "peer update")
        try writePeerSkill("new", content: "peer new")
        try writePeerSkill("conflict", content: "peer conflict")
        try writePeerSkill("local-only", content: "base")
        try writePeerFile("shared/.DS_Store", content: "finder metadata")
        try writePeerFile("shared/memory.md.tmp", content: "temporary write")

        var initialSettings = BackupSettings(
            destinationRootPath: destination.path,
            enabledItemIDs: ["codex-skills"],
            trustedMachineNames: ["Peer-Mac"],
            syncStates: [
                "Codex/skills/shared/SKILL.md": SyncFileState(
                    sha256: sha256("local base"),
                    updatedAt: Date(timeIntervalSince1970: 0),
                    machineName: "Peer-Mac"
                ),
                "Codex/skills/conflict/SKILL.md": SyncFileState(
                    sha256: sha256("base"),
                    updatedAt: Date(timeIntervalSince1970: 0),
                    machineName: "Peer-Mac"
                ),
                "Codex/skills/local-only/SKILL.md": SyncFileState(
                    sha256: sha256("base"),
                    updatedAt: Date(timeIntervalSince1970: 0),
                    machineName: "Peer-Mac"
                ),
                "Codex/skills/deleted/SKILL.md": SyncFileState(
                    sha256: sha256("delete me"),
                    updatedAt: Date(timeIntervalSince1970: 0),
                    machineName: "Peer-Mac"
                )
            ]
        )

        localManifest = try BackupService(fileManager: fileManager).runBackup(
            settings: initialSettings,
            items: DefaultBackupItems.items(homeDirectory: home, fileManager: fileManager),
            now: Date(timeIntervalSince1970: 0)
        ).manifest

        try writePeerManifest()
        initialSettings.syncTombstones = [:]
        settings = initialSettings
    }

    func cleanUp() {
        try? fileManager.removeItem(at: root)
    }

    func makePlans() throws -> [PeerSyncPlan] {
        try PeerSyncService(fileManager: fileManager).makePlans(
            settings: settings,
            localManifest: localManifest,
            homeDirectory: home,
            items: DefaultBackupItems.items(homeDirectory: home, fileManager: fileManager)
        )
    }

    private func writeLocalSkill(_ name: String, content: String) throws {
        let url = home.appending(relativePath: ".codex/skills/\(name)/SKILL.md")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePeerSkill(_ name: String, content: String) throws {
        let url = peerLatest.appending(relativePath: "Codex/skills/\(name)/SKILL.md")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePeerFile(_ relativePath: String, content: String) throws {
        let url = peerLatest.appending(relativePath: "Codex/skills/\(relativePath)")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePeerManifest() throws {
        var files = try ["shared", "new", "conflict", "local-only"].map { name in
            let url = peerLatest.appending(relativePath: "Codex/skills/\(name)/SKILL.md")
            return BackupManifestFile(
                itemID: "codex-skills",
                itemDisplayName: "Custom Codex skills",
                relativePath: "\(name)/SKILL.md",
                backupRelativePath: "Codex/skills/\(name)/SKILL.md",
                sourcePath: "/peer/.codex/skills/\(name)/SKILL.md",
                byteCount: UInt64((try Data(contentsOf: url)).count),
                sha256: try fileSHA256(url),
                modifiedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let metadataURL = peerLatest.appending(relativePath: "Codex/skills/shared/.DS_Store")
        files.append(BackupManifestFile(
            itemID: "codex-skills",
            itemDisplayName: "Custom Codex skills",
            relativePath: "shared/.DS_Store",
            backupRelativePath: "Codex/skills/shared/.DS_Store",
            sourcePath: "/peer/.codex/skills/shared/.DS_Store",
            byteCount: UInt64((try Data(contentsOf: metadataURL)).count),
            sha256: try fileSHA256(metadataURL),
            modifiedAt: Date(timeIntervalSince1970: 0)
        ))
        let tempURL = peerLatest.appending(relativePath: "Codex/skills/shared/memory.md.tmp")
        files.append(BackupManifestFile(
            itemID: "codex-skills",
            itemDisplayName: "Custom Codex skills",
            relativePath: "shared/memory.md.tmp",
            backupRelativePath: "Codex/skills/shared/memory.md.tmp",
            sourcePath: "/peer/.codex/skills/shared/memory.md.tmp",
            byteCount: UInt64((try Data(contentsOf: tempURL)).count),
            sha256: try fileSHA256(tempURL),
            modifiedAt: Date(timeIntervalSince1970: 0)
        ))

        let manifest = BackupManifest(
            appName: "Codex Keep",
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            machineName: "Peer-Mac",
            items: [
                BackupManifestItem(
                    id: "codex-skills",
                    displayName: "Custom Codex skills",
                    sourcePath: "/peer/.codex/skills",
                    destinationPath: "/peer/latest/Codex/skills",
                    status: .copied,
                    fileCount: files.count,
                    byteCount: files.reduce(0) { $0 + $1.byteCount },
                    message: nil
                )
            ],
            files: files,
            tombstones: [
                SyncTombstone(
                    backupRelativePath: "Codex/skills/deleted/SKILL.md",
                    deletedAt: Date(timeIntervalSince1970: 1),
                    machineName: "Peer-Mac"
                )
            ],
            warnings: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: peerLatest.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

private func sha256(_ string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func fileSHA256(_ url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
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
