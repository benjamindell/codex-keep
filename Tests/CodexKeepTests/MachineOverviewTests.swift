import Foundation
import Testing
@testable import CodexKeepCore

@Test func legacyManifestDoesNotInventAMachineRole() throws {
    let data = Data("""
    {"appName":"Codex Keep","schemaVersion":1,"createdAt":"2026-10-16T12:00:00Z","machineName":"Old-Mac","items":[],"warnings":[]}
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(BackupManifest.self, from: data)
    #expect(manifest.secondaryMachineMode == nil)
}

@Test func overviewUsesReadableGenerationAndKeepsMissingTrustedMachines() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = root.appendingPathComponent("Studio")
    let generations = SyncGenerationLayout.generationsURL(in: peer)
    try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_792_152_000)
    let manifest = BackupManifest(appName: "Codex Keep", schemaVersion: 1, createdAt: now,
                                  machineName: "Studio", items: [], warnings: [], secondaryMachineMode: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: generations.appendingPathComponent("20261016-120000.json"))
    // A newer incomplete generation must not hide the last readable one.
    try Data("incomplete".utf8).write(to: generations.appendingPathComponent("20261016-130000.json"))
    let unrelated = root.appendingPathComponent("Not-A-Machine")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    let settings = BackupSettings(destinationRootPath: root.path, enabledItemIDs: [], trustedMachineNames: ["Studio", "Offline-Mac"])
    let machines = MachineOverviewService().machines(settings: settings, currentMachineName: "Laptop")
    #expect(machines.map(\.name) == ["Laptop", "Offline-Mac", "Studio"])
    let studio = try #require(machines.first { $0.name == "Studio" })
    #expect(studio.secondaryMachineMode == true)
    #expect(studio.lastBackupAt == now)
    #expect(studio.isTrusted)
    #expect(machines.first?.secondaryMachineMode == false)
    #expect(machines.first { $0.name == "Offline-Mac" }?.lastBackupAt == nil)
}

@Test func overviewReadsLegacyUntrustedPeersAndRejectsMismatchedMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let latest = root.appendingPathComponent("Peer/latest")
    try FileManager.default.createDirectory(at: latest, withIntermediateDirectories: true)
    let manifest = BackupManifest(appName: "Codex Keep", schemaVersion: 1, createdAt: Date(),
                                  machineName: "Wrong-Mac", items: [], warnings: [])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: latest.appendingPathComponent("manifest.json"))
    let settings = BackupSettings(destinationRootPath: root.path, enabledItemIDs: [], secondaryMachineMode: true)
    var machines = MachineOverviewService().machines(settings: settings, currentMachineName: "Local")
    #expect(machines.first?.secondaryMachineMode == true)
    #expect(machines.last?.lastBackupAt == nil)
    var matching = manifest
    matching.machineName = "Peer"
    try encoder.encode(matching).write(to: latest.appendingPathComponent("manifest.json"))
    machines = MachineOverviewService().machines(settings: settings, currentMachineName: "Local")
    #expect(machines.last?.lastBackupAt != nil)
    #expect(machines.last?.secondaryMachineMode == nil)
    #expect(machines.last?.isTrusted == false)
}

@Test func backupPublishesRoleInLatestAndSyncGeneration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = BackupSettings(destinationRootPath: root.path, enabledItemIDs: [], secondaryMachineMode: true)
    let result = try BackupService().runBackup(settings: settings, items: [])
    #expect(result.manifest.secondaryMachineMode == true)
    let machines = MachineOverviewService().machines(settings: settings, currentMachineName: "Other")
    #expect(machines.first { $0.name == result.manifest.machineName }?.secondaryMachineMode == true)
}

@Test func removingMachinePersistsRevokesTrustAndPreservesBackups() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let latest = root.appendingPathComponent("Mini/latest")
    try FileManager.default.createDirectory(at: latest, withIntermediateDirectories: true)
    let backup = latest.appendingPathComponent("manifest.json")
    try Data("existing backup".utf8).write(to: backup)
    let settingsURL = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: settingsURL, homeDirectory: root)
    try store.update {
        $0.destinationRootPath = root.path
        $0.trustedMachineNames = ["Mini"]
        $0.automaticallySyncTrustedMachines = true
        $0.removeMachine("Mini", currentMachineName: "Laptop")
    }
    let reloaded = SettingsStore(settingsURL: settingsURL, homeDirectory: root)
    #expect(reloaded.settings.removedMachineNames == ["Mini"])
    #expect(reloaded.settings.trustedMachineNames.isEmpty)
    #expect(!reloaded.settings.automaticallySyncTrustedMachines)
    #expect(try Data(contentsOf: backup) == Data("existing backup".utf8))
    #expect(MachineOverviewService().machines(settings: reloaded.settings, currentMachineName: "Laptop").map(\.name) == ["Laptop"])
    try reloaded.update { $0.restoreMachine("Mini") }
    let machines = MachineOverviewService().machines(settings: reloaded.settings, currentMachineName: "Laptop")
    #expect(machines.map(\.name) == ["Laptop", "Mini"])
    #expect(machines.last?.isTrusted == false)
}

@Test func removingCurrentMacIsIgnoredAndOtherPeersStayTrusted() {
    var settings = BackupSettings(destinationRootPath: "/unused", enabledItemIDs: [],
                                  trustedMachineNames: ["Mini", "Studio"], automaticallySyncTrustedMachines: true)
    let original = settings
    settings.removeMachine("Laptop", currentMachineName: "Laptop")
    #expect(settings == original)
    settings.removeMachine("Mini", currentMachineName: "Laptop")
    #expect(settings.trustedMachineNames == ["Studio"])
    #expect(settings.automaticallySyncTrustedMachines)
}

@Test func oldSettingsDecodeWithoutRemovedMachines() throws {
    let data = Data("""
    {"destinationRootPath":"/backups","enabledItemIDs":[],"trustedMachineNames":["Studio"],"automaticallySyncTrustedMachines":true}
    """.utf8)
    let settings = try JSONDecoder().decode(BackupSettings.self, from: data)
    #expect(settings.removedMachineNames.isEmpty)
    #expect(settings.trustedMachineNames == ["Studio"])
    #expect(settings.automaticallySyncTrustedMachines)
}

@Test func removedPeerCannotSyncEvenWithStaleTrust() throws {
    var settings = BackupSettings(destinationRootPath: "/unused", enabledItemIDs: [], removedMachineNames: ["Mini", "Laptop"])
    settings.trustedMachineNames = ["Mini"]
    let local = BackupManifest(appName: "Codex Keep", schemaVersion: 1, createdAt: Date(),
                               machineName: "Laptop", items: [], warnings: [])
    #expect(try PeerSyncService().makePlans(settings: settings, localManifest: local, items: []).isEmpty)
    #expect(MachineOverviewService().machines(settings: settings, currentMachineName: "Laptop").map(\.name) == ["Laptop"])
}
