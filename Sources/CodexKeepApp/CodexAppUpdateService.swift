import AppKit
import CodexKeepCore
import Foundation
import Sparkle

@MainActor
final class CodexAppUpdateService {
    enum UpdateResult: Equatable {
        case skippedNotSecondary
        case skippedCodexMissing
        case skippedCodexBusy([String])
        case skippedAlreadyRunning
        case started(currentVersion: String, feedURL: String)
        case failed(String)
    }

    private let fileManager: FileManager
    private var activeSession: CodexAppUpdateSession?
    private var lastRunDate: Date?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func shouldRunDailyUpdate(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let lastRunDate else {
            return true
        }

        return !calendar.isDate(lastRunDate, inSameDayAs: now)
    }

    func runDailyUpdateIfNeeded(
        settings: BackupSettings,
        isBackingUp: Bool,
        isPullingRepositories: Bool,
        now: Date = Date(),
        log: @escaping (String) -> Void
    ) -> UpdateResult {
        guard settings.secondaryMachineMode else {
            return .skippedNotSecondary
        }

        guard shouldRunDailyUpdate(now: now) else {
            return .skippedAlreadyRunning
        }

        let result = runUpdate(
            isBackingUp: isBackingUp,
            isPullingRepositories: isPullingRepositories,
            log: log
        )
        lastRunDate = now
        return result
    }

    func runUpdate(
        isBackingUp: Bool,
        isPullingRepositories: Bool,
        log: @escaping (String) -> Void
    ) -> UpdateResult {
        guard activeSession == nil else {
            return .skippedAlreadyRunning
        }

        guard !isBackingUp, !isPullingRepositories else {
            let reasons = [
                isBackingUp ? "Codex Keep backup is running" : nil,
                isPullingRepositories ? "repository pull is running" : nil
            ].compactMap(\.self)
            return .skippedCodexBusy(reasons)
        }

        let codexBundleURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
        guard let codexBundle = Bundle(url: codexBundleURL),
              fileManager.fileExists(atPath: codexBundleURL.path)
        else {
            return .skippedCodexMissing
        }

        let busyReasons = codexBusyReasons()
        guard busyReasons.isEmpty else {
            return .skippedCodexBusy(busyReasons)
        }

        do {
            let feedURL = try codexSparkleFeedURL(from: codexBundleURL)
            let currentVersion = codexBundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let session = CodexAppUpdateSession(
                codexBundle: codexBundle,
                feedURL: feedURL,
                log: { [weak self] message in
                    log(message)
                    if message.hasPrefix("Codex app update finished") || message.hasPrefix("Codex app update aborted") {
                        self?.activeSession = nil
                    }
                }
            )
            activeSession = session
            try session.start()
            log("Codex app update started for \(currentVersion) using \(feedURL)")
            return .started(currentVersion: currentVersion, feedURL: feedURL)
        } catch {
            activeSession = nil
            return .failed(error.localizedDescription)
        }
    }

    private func codexBusyReasons() -> [String] {
        processLines().compactMap { line in
            if line.contains("/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://") {
                return "active Codex stdio app-server: \(line)"
            }

            if line.contains("/Applications/Codex.app/Contents/Resources/cua_node/bin/node ")
                && line.contains("kernel.js") {
                return "active Codex node kernel: \(line)"
            }

            return nil
        }
    }

    private func processLines() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid,ppid,stat,etime,command"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.contains("/Applications/Codex.app/") }
        } catch {
            return []
        }
    }

    private func codexSparkleFeedURL(from codexBundleURL: URL) throws -> String {
        let asarURL = codexBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("app.asar")
        let data = try Data(contentsOf: asarURL)
        guard data.count >= 16 else {
            throw CodexAppUpdateError.invalidAsarHeader
        }

        let headerSize = Int(data.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.load(fromByteOffset: 12, as: UInt32.self))
        })
        let headerStart = 16
        let headerEnd = headerStart + headerSize
        guard headerEnd <= data.count else {
            throw CodexAppUpdateError.invalidAsarHeader
        }

        let headerObject = try JSONSerialization.jsonObject(with: data.subdata(in: headerStart..<headerEnd))
        guard let header = headerObject as? [String: Any],
              let packageEntry = asarEntry(["package.json"], in: header),
              let offsetString = packageEntry["offset"] as? String,
              let offset = Int(offsetString),
              let size = packageEntry["size"] as? Int
        else {
            throw CodexAppUpdateError.missingCodexFeedURL
        }

        let fileStart = headerEnd + offset
        let fileEnd = fileStart + size
        guard fileStart >= headerEnd, fileEnd <= data.count else {
            throw CodexAppUpdateError.invalidAsarEntry
        }

        let packageObject = try JSONSerialization.jsonObject(with: data.subdata(in: fileStart..<fileEnd))
        guard let package = packageObject as? [String: Any],
              let feedURL = package["codexSparkleFeedUrl"] as? String,
              URL(string: feedURL) != nil
        else {
            throw CodexAppUpdateError.missingCodexFeedURL
        }

        return feedURL
    }

    private func asarEntry(_ path: [String], in node: [String: Any]) -> [String: Any]? {
        guard !path.isEmpty,
              let files = node["files"] as? [String: Any],
              let child = files[path[0]] as? [String: Any]
        else {
            return nil
        }

        if path.count == 1 {
            return child
        }

        return asarEntry(Array(path.dropFirst()), in: child)
    }
}

private enum CodexAppUpdateError: LocalizedError {
    case invalidAsarHeader
    case invalidAsarEntry
    case missingCodexFeedURL

    var errorDescription: String? {
        switch self {
        case .invalidAsarHeader:
            "Codex app.asar has an unsupported header."
        case .invalidAsarEntry:
            "Codex app.asar package metadata could not be read."
        case .missingCodexFeedURL:
            "Codex Sparkle feed URL was not found in Codex package metadata."
        }
    }
}

@MainActor
private final class CodexAppUpdateSession: NSObject, SPUUpdaterDelegate {
    private let feedURL: String
    private let userDriver: SilentCodexAppUpdateUserDriver
    private let log: (String) -> Void
    private lazy var updater = SPUUpdater(
        hostBundle: codexBundle,
        applicationBundle: codexBundle,
        userDriver: userDriver,
        delegate: self
    )

    private let codexBundle: Bundle

    init(codexBundle: Bundle, feedURL: String, log: @escaping (String) -> Void) {
        self.codexBundle = codexBundle
        self.feedURL = feedURL
        self.log = log
        self.userDriver = SilentCodexAppUpdateUserDriver(log: log)
    }

    func start() throws {
        try updater.start()
        updater.checkForUpdates()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated {
            feedURL
        }
    }

    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            log("Codex app update found \(item.displayVersionString) (\(item.versionString))")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        MainActor.assumeIsolated {
            log("Codex app update found no update: \(error.localizedDescription)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        MainActor.assumeIsolated {
            log("Codex app update downloading \(item.displayVersionString) (\(item.versionString))")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            log("Codex app update downloaded \(item.displayVersionString) (\(item.versionString))")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        MainActor.assumeIsolated {
            log("Codex app update failed to download \(item.displayVersionString): \(error.localizedDescription)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            log("Codex app update installing \(item.displayVersionString) (\(item.versionString))")
        }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            log("Codex app update will relaunch Codex")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        MainActor.assumeIsolated {
            log("Codex app update aborted: \(error.localizedDescription)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                log("Codex app update finished with error: \(error.localizedDescription)")
            } else {
                log("Codex app update finished")
            }
        }
    }
}

@MainActor
private final class SilentCodexAppUpdateUserDriver: NSObject, SPUUserDriver {
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    nonisolated func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            automaticUpdateDownloading: NSNumber(value: true),
            sendSystemProfile: false
        ))
    }

    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            log("Codex app update check started")
        }
    }

    nonisolated func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            log("Codex app update offered \(appcastItem.displayVersionString) (\(appcastItem.versionString))")
        }
        reply(appcastItem.isInformationOnlyUpdate ? SPUUserUpdateChoice.dismiss : SPUUserUpdateChoice.install)
    }

    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    nonisolated func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    nonisolated func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            log("Codex app update UI driver error: \(error.localizedDescription)")
        }
        acknowledgement()
    }

    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            log("Codex app update download started")
        }
    }

    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {}

    nonisolated func showDownloadDidStartExtractingUpdate() {
        MainActor.assumeIsolated {
            log("Codex app update extracting")
        }
    }

    nonisolated func showExtractionReceivedProgress(_ progress: Double) {}

    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            log("Codex app update ready to install and relaunch")
        }
        reply(SPUUserUpdateChoice.install)
    }

    nonisolated func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        MainActor.assumeIsolated {
            log("Codex app update installing; Codex terminated: \(applicationTerminated)")
        }
    }

    nonisolated func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            log("Codex app update installed; relaunched: \(relaunched)")
        }
        acknowledgement()
    }

    nonisolated func dismissUpdateInstallation() {}
}
