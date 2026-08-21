import Foundation

enum SyncPathPolicy {
    static func isSyncable(_ backupRelativePath: String) -> Bool {
        !backupRelativePath.hasPrefix("Codex/automations/")
            && backupRelativePath != "Codex/automations"
            && !BackupPathFilter.shouldExclude(relativePath: backupRelativePath)
    }
}

enum SyncGenerationLayout {
    static let directoryName = "Sync"
    static let generationsDirectoryName = "Generations"
    static let blobsDirectoryName = "Blobs"
    static let retainedGenerationCount = 7

    static func rootURL(in machineRoot: URL) -> URL {
        machineRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func generationsURL(in machineRoot: URL) -> URL {
        rootURL(in: machineRoot).appendingPathComponent(generationsDirectoryName, isDirectory: true)
    }

    static func blobsURL(in machineRoot: URL) -> URL {
        rootURL(in: machineRoot).appendingPathComponent(blobsDirectoryName, isDirectory: true)
    }

    static func blobURL(for sha256: String, in blobsURL: URL) -> URL {
        let shard = String(sha256.prefix(2))
        return blobsURL
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent(sha256)
    }

    static func generationFileName(now: Date, uuid: UUID = UUID()) -> String {
        "\(generationDateFormatter.string(from: now))-\(uuid.uuidString).json"
    }

    private static let generationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}

enum SyncFileReadiness {
    static func isMaterialized(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]) else {
            return false
        }

        let logicalSize = values.fileSize ?? 0
        let allocatedSize = max(
            values.totalFileAllocatedSize ?? 0,
            values.fileAllocatedSize ?? 0
        )
        if logicalSize > 0, allocatedSize == 0 {
            return false
        }

        guard values.isUbiquitousItem == true else {
            return true
        }

        return values.ubiquitousItemDownloadingStatus == .current
            || values.ubiquitousItemDownloadingStatus == .downloaded
    }
}
