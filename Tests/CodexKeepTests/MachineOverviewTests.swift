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
