import Foundation

enum PayloadArchiveError: LocalizedError, Equatable {
    case dittoFailed(arguments: [String], status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .dittoFailed(arguments, status, message):
            "ditto \(arguments.joined(separator: " ")) failed with status \(status): \(message)"
        }
    }
}

enum PayloadArchive {
    static let fileName = ".codex-keep-payload.zip"

    static func create(contentsOf sourceDirectoryURL: URL, archiveURL: URL) throws {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }

        try runDitto(arguments: [
            "-c",
            "-k",
            sourceDirectoryURL.path,
            archiveURL.path
        ])
    }

    static func extract(archiveURL: URL, to destinationDirectoryURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
        try runDitto(arguments: [
            "-x",
            "-k",
            archiveURL.path,
            destinationDirectoryURL.path
        ])
    }

    private static func runDitto(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PayloadArchiveError.dittoFailed(
                arguments: arguments,
                status: process.terminationStatus,
                message: message
            )
        }
    }
}
