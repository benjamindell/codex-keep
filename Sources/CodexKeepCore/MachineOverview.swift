import Foundation

public struct MachineOverview: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let isCurrent: Bool
    public let isTrusted: Bool
    public let secondaryMachineMode: Bool?
    public let lastBackupAt: Date?

    public init(name: String, isCurrent: Bool, isTrusted: Bool, secondaryMachineMode: Bool?, lastBackupAt: Date?) {
        self.name = name
        self.isCurrent = isCurrent
        self.isTrusted = isTrusted
        self.secondaryMachineMode = secondaryMachineMode
        self.lastBackupAt = lastBackupAt
    }
}

/// Reads small, locally available manifests only. Opening the menu must never wait for iCloud hydration.
public struct MachineOverviewService: Sendable {
    public init() {}

    public func machines(settings: BackupSettings, currentMachineName: String = Machine.currentName()) -> [MachineOverview] {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: settings.destinationRootPath)
        let directories = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        var names = settings.trustedMachineNames.union([currentMachineName])
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let latest = directory.appendingPathComponent("latest")
            let generations = SyncGenerationLayout.generationsURL(in: directory)
            if fileManager.fileExists(atPath: latest.appendingPathComponent("manifest.json").path)
                || fileManager.fileExists(atPath: latest.appendingPathComponent(".manifest.json.icloud").path)
                || fileManager.fileExists(atPath: generations.path) {
                names.insert(directory.lastPathComponent)
            }
        }
        return names.sorted {
            if $0 == currentMachineName { return true }
            if $1 == currentMachineName { return false }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }.map { name in
            let manifest = newestLocalManifest(in: root.appendingPathComponent(name), machineName: name)
            return MachineOverview(
                name: name, isCurrent: name == currentMachineName,
                isTrusted: settings.trustedMachineNames.contains(name),
                secondaryMachineMode: name == currentMachineName ? settings.secondaryMachineMode : manifest?.secondaryMachineMode,
                lastBackupAt: manifest?.createdAt
            )
        }
    }

    private func newestLocalManifest(in machineRoot: URL, machineName: String) -> BackupManifest? {
        let fileManager = FileManager.default
        let generations = (try? fileManager.contentsOfDirectory(
            at: SyncGenerationLayout.generationsURL(in: machineRoot),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = generations.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            + [machineRoot.appendingPathComponent("latest/manifest.json")]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in candidates {
            guard SyncFileReadiness.isMaterialized(url, fileManager: fileManager),
                  let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(BackupManifest.self, from: data),
                  manifest.schemaVersion == 1, manifest.machineName == machineName else { continue }
            return manifest
        }
        return nil
    }
}
