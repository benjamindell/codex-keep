import Foundation

enum BackupRetentionPolicy {
    static let safetySnapshotRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static let minimumRetainedSafetySnapshotCount = 20
    static let maximumSafetySnapshotRemovalsPerRun = 100
    static let staleWorkingItemAge: TimeInterval = 24 * 60 * 60
    static let incompleteAutomationMoveAge: TimeInterval = 7 * 24 * 60 * 60

    private static let safetyFolderNames = [
        "Sync Safety",
        "Restore Safety",
        "Automation Move Safety"
    ]

    static func pruneMachineRoot(
        _ machineRoot: URL,
        fileManager: FileManager,
        now: Date
    ) throws {
        for folderName in safetyFolderNames {
            try pruneSafetySnapshots(
                in: machineRoot.appendingPathComponent(folderName, isDirectory: true),
                fileManager: fileManager,
                now: now
            )
        }

        try pruneStaleWorkingItems(
            in: machineRoot,
            fileManager: fileManager,
            now: now
        )
        try pruneIncompleteAutomationMoves(
            in: machineRoot.appendingPathComponent("Automation Moves", isDirectory: true),
            fileManager: fileManager,
            now: now
        )
    }

    static func pruneSafetySnapshots(
        in snapshotsURL: URL,
        fileManager: FileManager,
        now: Date
    ) throws {
        guard fileManager.fileExists(atPath: snapshotsURL.path) else {
            return
        }

        let snapshots = try fileManager.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let date = safetySnapshotDateFormatter.date(from: url.lastPathComponent)
            else {
                return nil
            }
            return (url, date)
        }
        .sorted { first, second in
            if first.date != second.date {
                return first.date > second.date
            }
            return first.url.lastPathComponent > second.url.lastPathComponent
        }

        let minimumRetainedURLs = Set(
            snapshots.prefix(minimumRetainedSafetySnapshotCount).map { $0.url.standardizedFileURL }
        )
        let cutoff = now.addingTimeInterval(-safetySnapshotRetentionInterval)
        let expiredSnapshots = snapshots.filter { snapshot in
            snapshot.date < cutoff
                && !minimumRetainedURLs.contains(snapshot.url.standardizedFileURL)
        }

        for snapshot in expiredSnapshots.suffix(maximumSafetySnapshotRemovalsPerRun) {
            try fileManager.removeItem(at: snapshot.url)
        }
    }

    private static func pruneStaleWorkingItems(
        in machineRoot: URL,
        fileManager: FileManager,
        now: Date
    ) throws {
        let workingDirectories = [
            machineRoot,
            machineRoot.appendingPathComponent("Snapshots", isDirectory: true),
            SyncGenerationLayout.generationsURL(in: machineRoot),
            machineRoot.appendingPathComponent("Automation Moves", isDirectory: true)
        ]
        let cutoff = now.addingTimeInterval(-staleWorkingItemAge)

        for directoryURL in workingDirectories where fileManager.fileExists(atPath: directoryURL.path) {
            let contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )

            for url in contents where isManagedWorkingItem(url.lastPathComponent) {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff
                else {
                    continue
                }
                try fileManager.removeItem(at: url)
            }
        }
    }

    private static func pruneIncompleteAutomationMoves(
        in movesURL: URL,
        fileManager: FileManager,
        now: Date
    ) throws {
        guard fileManager.fileExists(atPath: movesURL.path) else {
            return
        }

        let cutoff = now.addingTimeInterval(-incompleteAutomationMoveAge)
        let moves = try fileManager.contentsOfDirectory(
            at: movesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for moveURL in moves {
            guard let values = try? moveURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .contentModificationDateKey
            ]),
                  values.isDirectory == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff,
                  !fileManager.fileExists(atPath: moveURL.appendingPathComponent("manifest.json").path)
            else {
                continue
            }
            try fileManager.removeItem(at: moveURL)
        }
    }

    private static func isManagedWorkingItem(_ name: String) -> Bool {
        name.hasPrefix(".staging-")
            || name.hasPrefix(".payload-")
            || name.hasPrefix(".publish-")
            || name.hasPrefix(".automation-move-")
            || (name.hasPrefix(".") && name.contains("-publish-"))
    }

    private static let safetySnapshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
