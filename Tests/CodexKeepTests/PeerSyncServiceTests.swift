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
    #expect(items["Codex/skills/shared/README.md"]?.status == .incomingNew)
    #expect(items["Codex/skills/new/SKILL.md"]?.status == .incomingNew)
    #expect(items["Codex/skills/conflict/SKILL.md"]?.status == .conflict)
    #expect(items["Codex/skills/local-only/SKILL.md"]?.status == .localChanged)
    #expect(items["Codex/skills/deleted/SKILL.md"]?.status == .peerDeletedReviewRequired)
    #expect(items["Codex/config.toml"]?.status == .incomingChanged)
    #expect(items["Codex/skills/shared/.DS_Store"] == nil)
    #expect(items["Codex/skills/shared/memory.md.tmp"] == nil)
    #expect(items["Codex/automations/daily-report/automation.toml"] == nil)
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
    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/skills/shared/README.md"), encoding: .utf8) == "peer readme")
    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/skills/new/SKILL.md"), encoding: .utf8) == "peer new")
    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/skills/conflict/SKILL.md"), encoding: .utf8) == "local conflict")
    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/config.toml"), encoding: .utf8) == "model = \"peer\"")
    #expect(!fixture.fileManager.fileExists(atPath: fixture.home.appending(relativePath: ".codex/skills/deleted/SKILL.md").path))
    #expect(fixture.fileManager.fileExists(atPath: fixture.home.appending(relativePath: ".codex/skills/conflict/SKILL.conflict-Peer-Mac-19700101-010000.md").path))
    #expect(fixture.fileManager.fileExists(atPath: result.safetySnapshotURL.appendingPathComponent("manifest.json").path))
    #expect(result.updatedSettings.syncStates["Codex/skills/shared/SKILL.md"]?.sha256 == sha256("peer update"))
    #expect(result.updatedSettings.syncStates["Codex/config.toml"]?.sha256 == sha256("model = \"peer\""))
    #expect(result.updatedSettings.syncStates["Codex/skills/deleted/SKILL.md"]?.sha256 == nil)
    #expect(result.updatedSettings.syncTombstones["Codex/skills/deleted/SKILL.md"] != nil)
}

@Test func reviewedConfigConflictReplacesLocalConfigAndRecordsSyncState() throws {
    let fixture = try PeerSyncFixture()
    defer { fixture.cleanUp() }

    fixture.settings.syncStates.removeValue(forKey: "Codex/config.toml")

    let plans = try fixture.makePlans()
    let item = try #require(plans.flatMap(\.items).first {
        $0.backupRelativePath == "Codex/config.toml"
    })
    #expect(item.status == .conflict)
    #expect(item.replacesLocalWhenReviewed)

    let result = try PeerSyncService(fileManager: fixture.fileManager).apply(
        plans: plans,
        selectedItemIDs: [item.id],
        settings: fixture.settings,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.appliedItemCount == 1)
    #expect(result.conflictCopyCount == 0)
    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/config.toml"), encoding: .utf8) == "model = \"peer\"")
    #expect(!fixture.fileManager.fileExists(atPath: fixture.home.appending(relativePath: ".codex/config.conflict-Peer-Mac-19700101-010000.toml").path))
    #expect(result.updatedSettings.syncStates["Codex/config.toml"]?.sha256 == sha256("model = \"peer\""))
}

@Test func peerSyncSkipsManifestFilesMissingAtApplyTime() throws {
    let fixture = try PeerSyncFixture()
    defer { fixture.cleanUp() }

    let plans = try fixture.makePlans()
    let selectedIDs = Set(plans.flatMap(\.items).compactMap { item in
        item.backupRelativePath == "Codex/skills/new/SKILL.md" ? item.id : nil
    })
    try fixture.fileManager.removeItem(at: fixture.peerLatest.appending(relativePath: "Codex/skills/new/SKILL.md"))

    let result = try PeerSyncService(fileManager: fixture.fileManager).apply(
        plans: plans,
        selectedItemIDs: selectedIDs,
        settings: fixture.settings,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.appliedItemCount == 0)
    #expect(result.skippedItemCount == 1)
    #expect(result.skippedBackupRelativePaths == ["Codex/skills/new/SKILL.md"])
    #expect(!fixture.fileManager.fileExists(atPath: fixture.home.appending(relativePath: ".codex/skills/new/SKILL.md").path))
}

@Test func peerSyncFallsBackToPayloadArchiveWhenPeerTreeIsNotHydrated() throws {
    let fixture = try PeerSyncFixture()
    defer { fixture.cleanUp() }

    try fixture.writePeerPayloadArchive()
    let plans = try fixture.makePlans()
    let item = try #require(plans.flatMap(\.items).first {
        $0.backupRelativePath == "Codex/skills/shared/README.md"
    })
    try fixture.fileManager.removeItem(at: fixture.peerLatest.appending(relativePath: "Codex/skills/shared/README.md"))

    let result = try PeerSyncService(fileManager: fixture.fileManager).apply(
        plans: plans,
        selectedItemIDs: [item.id],
        settings: fixture.settings,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.appliedItemCount == 1)
    #expect(result.skippedItemCount == 0)
    #expect(try String(contentsOf: fixture.home.appending(relativePath: ".codex/skills/shared/README.md"), encoding: .utf8) == "peer readme")
}

@Test func peerSyncOnlyPlansRepositoryDevFilesForMatchingLocalRepos() throws {
    let fixture = try PeerSyncFixture()
    defer { fixture.cleanUp() }

    fixture.settings.syncRepositoryDevFiles = true
    try fixture.writePeerRepositoryDevFile()

    var plans = try fixture.makePlans()
    #expect(!plans.flatMap(\.items).contains { $0.backupRelativePath == "Git Repos/github.com/example/example-app/.env" })

    try writeGitConfig(
        in: fixture.home.appending(relativePath: "Repositories/example-app"),
        originURL: "git@github.com:example/example-app.git",
        fileManager: fixture.fileManager
    )

    plans = try fixture.makePlans()
    let item = try #require(plans.flatMap(\.items).first {
        $0.backupRelativePath == "Git Repos/github.com/example/example-app/.env"
    })
    #expect(item.status == .incomingNew)
    #expect(item.targetPath.hasSuffix("/Home/Repositories/example-app/.env"))
}

@Test func peerSyncSafetySnapshotToleratesDuplicateTargets() throws {
    let fixture = try PeerSyncFixture()
    defer { fixture.cleanUp() }

    let plan = try #require(fixture.makePlans().first)
    let item = try #require(plan.items.first { $0.backupRelativePath == "Codex/skills/shared/SKILL.md" })
    var duplicate = item
    duplicate.id = "duplicate-\(item.id)"
    let duplicatedPlan = PeerSyncPlan(
        peerName: plan.peerName,
        sourceURL: plan.sourceURL,
        manifest: plan.manifest,
        items: [item, duplicate],
        warnings: []
    )

    let result = try PeerSyncService(fileManager: fixture.fileManager).apply(
        plans: [duplicatedPlan],
        selectedItemIDs: [item.id, duplicate.id],
        settings: fixture.settings,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.appliedItemCount == 2)
    #expect(fixture.fileManager.fileExists(atPath: result.safetySnapshotURL.appendingPathComponent("manifest.json").path))
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

@Test func peerSyncSkipsTrustedPeersWhoseManifestIsNotReady() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let peerLatest = root.appending(relativePath: "Ben-s-MacBook-Pro/latest")
    try fileManager.createDirectory(at: peerLatest, withIntermediateDirectories: true)

    let settings = BackupSettings(
        destinationRootPath: root.path,
        enabledItemIDs: ["codex-config"],
        trustedMachineNames: ["Ben-s-MacBook-Pro"]
    )
    let localManifest = BackupManifest(
        appName: "Codex Keep",
        schemaVersion: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        machineName: "Ben-s-Mac-Mini",
        items: [],
        files: [],
        tombstones: [],
        warnings: []
    )

    let plans = try PeerSyncService(fileManager: fileManager).makePlans(
        settings: settings,
        localManifest: localManifest,
        homeDirectory: home
    )

    #expect(plans.isEmpty)
}

@Test func peerSyncSkipsGitInternalsFromOlderPeerManifests() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let peerLatest = root.appending(relativePath: "Ben-s-MacBook-Pro/latest")
    try fileManager.createDirectory(at: peerLatest, withIntermediateDirectories: true)
    let manifest = BackupManifest(
        appName: "Codex Keep",
        schemaVersion: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        machineName: "Ben-s-MacBook-Pro",
        items: [],
        files: [
            BackupManifestFile(
                itemID: "codex-markdown-memories",
                itemDisplayName: "Codex memories",
                relativePath: ".git/index",
                backupRelativePath: "Codex/memories/.git/index",
                sourcePath: "/peer/.codex/memories/.git/index",
                byteCount: 4,
                sha256: sha256("git\n"),
                modifiedAt: Date(timeIntervalSince1970: 0)
            ),
            BackupManifestFile(
                itemID: "codex-markdown-memories",
                itemDisplayName: "Codex memories",
                relativePath: "memory_summary.md",
                backupRelativePath: "Codex/memories/memory_summary.md",
                sourcePath: "/peer/.codex/memories/memory_summary.md",
                byteCount: 7,
                sha256: sha256("summary"),
                modifiedAt: Date(timeIntervalSince1970: 0)
            )
        ],
        tombstones: [],
        warnings: []
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: peerLatest.appendingPathComponent("manifest.json"), options: .atomic)

    let plans = try PeerSyncService(fileManager: fileManager).makePlans(
        settings: BackupSettings(
            destinationRootPath: root.path,
            enabledItemIDs: ["codex-markdown-memories"],
            trustedMachineNames: ["Ben-s-MacBook-Pro"]
        ),
        localManifest: BackupManifest(
            appName: "Codex Keep",
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            machineName: "Ben-s-Mac-Mini",
            items: [],
            files: [],
            tombstones: [],
            warnings: []
        ),
        homeDirectory: home,
        items: [
            BackupItem(
                id: "codex-markdown-memories",
                displayName: "Codex memories",
                sourcePath: home.appending(relativePath: ".codex/memories").path,
                destinationPath: "Codex/memories"
            )
        ]
    )

    let items = Dictionary(uniqueKeysWithValues: plans.flatMap(\.items).map { ($0.backupRelativePath, $0) })
    #expect(items["Codex/memories/.git/index"] == nil)
    #expect(items["Codex/memories/memory_summary.md"]?.status == .incomingNew)
}

@Test func peerSyncIgnoresConfigDeletionTombstones() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let configURL = home.appending(relativePath: ".codex/config.toml")
    let peerLatest = root.appending(relativePath: "Ben-s-MacBook-Pro/latest")
    try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: peerLatest, withIntermediateDirectories: true)
    try "model = \"local\"".write(to: configURL, atomically: true, encoding: .utf8)

    let manifest = BackupManifest(
        appName: "Codex Keep",
        schemaVersion: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        machineName: "Ben-s-MacBook-Pro",
        items: [],
        files: [],
        tombstones: [
            SyncTombstone(
                backupRelativePath: "Codex/config.toml",
                deletedAt: Date(timeIntervalSince1970: 1),
                machineName: "Ben-s-MacBook-Pro"
            )
        ],
        warnings: []
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: peerLatest.appendingPathComponent("manifest.json"), options: .atomic)

    let localConfigFile = BackupManifestFile(
        itemID: "codex-config",
        itemDisplayName: "Codex config",
        relativePath: "",
        backupRelativePath: "Codex/config.toml",
        sourcePath: configURL.path,
        byteCount: UInt64((try Data(contentsOf: configURL)).count),
        sha256: try fileSHA256(configURL),
        modifiedAt: Date(timeIntervalSince1970: 0)
    )

    let plans = try PeerSyncService(fileManager: fileManager).makePlans(
        settings: BackupSettings(
            destinationRootPath: root.path,
            enabledItemIDs: ["codex-config"],
            trustedMachineNames: ["Ben-s-MacBook-Pro"],
            syncStates: [
                "Codex/config.toml": SyncFileState(
                    sha256: localConfigFile.sha256,
                    updatedAt: Date(timeIntervalSince1970: 0),
                    machineName: "Ben-s-MacBook-Pro"
                )
            ]
        ),
        localManifest: BackupManifest(
            appName: "Codex Keep",
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            machineName: "Ben-s-Mac-Mini",
            items: [],
            files: [localConfigFile],
            tombstones: [],
            warnings: []
        ),
        homeDirectory: home,
        items: [
            BackupItem(
                id: "codex-config",
                displayName: "Codex config",
                sourcePath: configURL.path,
                destinationPath: "Codex/config.toml"
            )
        ]
    )

    #expect(plans.flatMap(\.items).isEmpty)
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
        try writeLocalConfig(content: "model = \"base\"")
        try writePeerSkill("shared", content: "peer update")
        try writePeerFile("shared/README.md", content: "peer readme")
        try writePeerSkill("new", content: "peer new")
        try writePeerSkill("conflict", content: "peer conflict")
        try writePeerSkill("local-only", content: "base")
        try writePeerConfig(content: "model = \"peer\"")
        try writePeerFile("shared/.DS_Store", content: "finder metadata")
        try writePeerFile("shared/memory.md.tmp", content: "temporary write")
        try writePeerAutomation("daily-report", content: "name = \"Daily\"")

        var initialSettings = BackupSettings(
            destinationRootPath: destination.path,
            enabledItemIDs: ["codex-automations", "codex-config", "codex-skills"],
            trustedMachineNames: ["Peer-Mac"],
            syncStates: [
                "Codex/config.toml": SyncFileState(
                    sha256: sha256("model = \"base\""),
                    updatedAt: Date(timeIntervalSince1970: 0),
                    machineName: "Peer-Mac"
                ),
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

    func writePeerPayloadArchive() throws {
        let temporaryArchiveURL = root.appendingPathComponent("peer-payload.zip")
        try PayloadArchive.create(contentsOf: peerLatest, archiveURL: temporaryArchiveURL)
        try fileManager.copyItem(
            at: temporaryArchiveURL,
            to: peerLatest.appendingPathComponent(PayloadArchive.fileName)
        )
    }

    func writePeerRepositoryDevFile() throws {
        let relativePath = "Git Repos/github.com/example/example-app/.env"
        let url = peerLatest.appending(relativePath: relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "SECRET=peer".write(to: url, atomically: true, encoding: .utf8)

        try writePeerManifest(extraFiles: [
            BackupManifestFile(
                itemID: "git-repo-dev-github.com-example-example-app",
                itemDisplayName: "Local repo dev files: example-app",
                relativePath: ".env",
                backupRelativePath: relativePath,
                sourcePath: "/peer/Repositories/example-app/.env",
                byteCount: UInt64((try Data(contentsOf: url)).count),
                sha256: try fileSHA256(url),
                modifiedAt: Date(timeIntervalSince1970: 0)
            )
        ])
    }

    private func writeLocalSkill(_ name: String, content: String) throws {
        let url = home.appending(relativePath: ".codex/skills/\(name)/SKILL.md")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeLocalConfig(content: String) throws {
        let url = home.appending(relativePath: ".codex/config.toml")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePeerSkill(_ name: String, content: String) throws {
        let url = peerLatest.appending(relativePath: "Codex/skills/\(name)/SKILL.md")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePeerConfig(content: String) throws {
        let url = peerLatest.appending(relativePath: "Codex/config.toml")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePeerFile(_ relativePath: String, content: String) throws {
        let url = peerLatest.appending(relativePath: "Codex/skills/\(relativePath)")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePeerAutomation(_ name: String, content: String) throws {
        let url = peerLatest.appending(relativePath: "Codex/automations/\(name)/automation.toml")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePeerManifest(extraFiles: [BackupManifestFile] = []) throws {
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
        let readmeURL = peerLatest.appending(relativePath: "Codex/skills/shared/README.md")
        files.append(BackupManifestFile(
            itemID: "codex-skills",
            itemDisplayName: "Custom Codex skills",
            relativePath: "shared/README.md",
            backupRelativePath: "Codex/skills/shared/README.md",
            sourcePath: "/peer/.codex/skills/shared/README.md",
            byteCount: UInt64((try Data(contentsOf: readmeURL)).count),
            sha256: try fileSHA256(readmeURL),
            modifiedAt: Date(timeIntervalSince1970: 0)
        ))
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
        let automationURL = peerLatest.appending(relativePath: "Codex/automations/daily-report/automation.toml")
        files.append(BackupManifestFile(
            itemID: "codex-automations",
            itemDisplayName: "Codex automations",
            relativePath: "daily-report/automation.toml",
            backupRelativePath: "Codex/automations/daily-report/automation.toml",
            sourcePath: "/peer/.codex/automations/daily-report/automation.toml",
            byteCount: UInt64((try Data(contentsOf: automationURL)).count),
            sha256: try fileSHA256(automationURL),
            modifiedAt: Date(timeIntervalSince1970: 0)
        ))
        let configURL = peerLatest.appending(relativePath: "Codex/config.toml")
        files.append(BackupManifestFile(
            itemID: "codex-config",
            itemDisplayName: "Codex config",
            relativePath: "",
            backupRelativePath: "Codex/config.toml",
            sourcePath: "/peer/.codex/config.toml",
            byteCount: UInt64((try Data(contentsOf: configURL)).count),
            sha256: try fileSHA256(configURL),
            modifiedAt: Date(timeIntervalSince1970: 0)
        ))
        files.append(contentsOf: extraFiles)

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
                ),
                BackupManifestItem(
                    id: "codex-config",
                    displayName: "Codex config",
                    sourcePath: "/peer/.codex/config.toml",
                    destinationPath: "/peer/latest/Codex/config.toml",
                    status: .copied,
                    fileCount: 1,
                    byteCount: UInt64((try Data(contentsOf: configURL)).count),
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

private func writeGitConfig(in repository: URL, originURL: String, fileManager: FileManager) throws {
    let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try """
    [remote "origin"]
        url = \(originURL)
    """.write(to: gitDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
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
