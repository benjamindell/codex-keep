import Darwin
import Foundation

public enum RepositoryPullStatus: String, Codable, Equatable, Sendable {
    case upToDate
    case pulledFastForward
    case pulledMerge
    case skippedDirty
    case skippedDetachedHead
    case skippedNoUpstream
    case skippedMergeInProgress
    case skippedLocalAhead
    case skippedConflicts
    case skippedTimedOut
    case failed
}

public struct RepositoryPullResult: Codable, Equatable, Sendable {
    public var repositoryName: String
    public var repositoryPath: String
    public var status: RepositoryPullStatus
    public var message: String

    public init(repositoryName: String, repositoryPath: String, status: RepositoryPullStatus, message: String) {
        self.repositoryName = repositoryName
        self.repositoryPath = repositoryPath
        self.status = status
        self.message = message
    }
}

public struct RepositoryPullRunResult: Codable, Equatable, Sendable {
    public var repositoriesRootPath: String
    public var startedAt: Date
    public var finishedAt: Date
    public var results: [RepositoryPullResult]

    public var pulledCount: Int {
        results.filter { $0.status == .pulledFastForward || $0.status == .pulledMerge }.count
    }

    public var skippedCount: Int {
        results.filter { $0.status.rawValue.hasPrefix("skipped") }.count
    }

    public var failedCount: Int {
        results.filter { $0.status == .failed }.count
    }
}

public final class RepositoryPullService {
    private let fileManager: FileManager
    private let gitExecutableURL: URL
    private let commandTimeout: TimeInterval
    private let safeAutoCommitExtensions: Set<String> = ["csv", "md", "xls", "xlsx", "yaml", "yml"]

    public init(
        fileManager: FileManager = .default,
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        commandTimeout: TimeInterval = 120
    ) {
        self.fileManager = fileManager
        self.gitExecutableURL = gitExecutableURL
        self.commandTimeout = commandTimeout
    }

    public func pullRepositories(
        repositoriesRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Repositories", isDirectory: true),
        now: Date = Date(),
        progress: ((String) -> Void)? = nil
    ) -> RepositoryPullRunResult {
        let repositories = discoverRepositories(in: repositoriesRoot)
        progress?("Found \(repositories.count) Git repositories in \(repositoriesRoot.standardizedFileURL.path)")
        let results = repositories.map { repositoryURL in
            progress?("Checking \(repositoryURL.lastPathComponent)")
            let result = pullRepository(at: repositoryURL)
            progress?("\(repositoryURL.lastPathComponent): \(result.status.rawValue) - \(result.message)")
            return result
        }
        return RepositoryPullRunResult(
            repositoriesRootPath: repositoriesRoot.standardizedFileURL.path,
            startedAt: now,
            finishedAt: Date(),
            results: results
        )
    }

    private func discoverRepositories(in repositoriesRoot: URL) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: repositoriesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children
            .filter { isGitRepository($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isGitRepository(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    private func pullRepository(at repositoryURL: URL) -> RepositoryPullResult {
        let repositoryName = repositoryURL.lastPathComponent
        let repositoryPath = repositoryURL.standardizedFileURL.path

        func result(_ status: RepositoryPullStatus, _ message: String) -> RepositoryPullResult {
            RepositoryPullResult(
                repositoryName: repositoryName,
                repositoryPath: repositoryPath,
                status: status,
                message: message
            )
        }

        do {
            guard !(try hasMergeOrRebaseInProgress(in: repositoryURL)) else {
                return result(.skippedMergeInProgress, "Skipped because a merge or rebase is already in progress.")
            }

            guard (try? runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repositoryURL)) != nil else {
                return result(.skippedDetachedHead, "Skipped because the repository is on a detached HEAD.")
            }

            guard (try? runGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repositoryURL)) != nil else {
                return result(.skippedNoUpstream, "Skipped because the current branch has no upstream.")
            }

            _ = try runGit(["fetch", "--prune"], in: repositoryURL)
            let localSHABeforeAutoCommit = try runGit(["rev-parse", "HEAD"], in: repositoryURL).trimmedOutput
            let upstreamSHABeforeAutoCommit = try runGit(["rev-parse", "@{u}"], in: repositoryURL).trimmedOutput
            let mergeBaseSHABeforeAutoCommit = try runGit(["merge-base", "HEAD", "@{u}"], in: repositoryURL).trimmedOutput

            let dirtyStatus = try dirtyWorktreeStatus(in: repositoryURL)
            let autoCommitMessage: String?
            if dirtyStatus.isEmpty {
                autoCommitMessage = nil
            } else {
                guard dirtyStatus.canAutoCommit else {
                    return result(
                        .skippedDirty,
                        "Skipped because the working tree has local changes outside safe generated artifacts."
                    )
                }

                guard localSHABeforeAutoCommit == upstreamSHABeforeAutoCommit
                    || mergeBaseSHABeforeAutoCommit == localSHABeforeAutoCommit else {
                    return result(
                        .skippedLocalAhead,
                        "Skipped because safe artifact auto-push would also push existing local commits."
                    )
                }

                autoCommitMessage = try autoCommitSafeArtifacts(dirtyStatus.entries, in: repositoryURL)
            }

            let localSHA = try runGit(["rev-parse", "HEAD"], in: repositoryURL).trimmedOutput
            let upstreamSHA = try runGit(["rev-parse", "@{u}"], in: repositoryURL).trimmedOutput
            let mergeBaseSHA = try runGit(["merge-base", "HEAD", "@{u}"], in: repositoryURL).trimmedOutput

            if localSHA == upstreamSHA {
                return result(.upToDate, [autoCommitMessage, "Already up to date."].compactMap { $0 }.joined(separator: " "))
            }

            if mergeBaseSHA == localSHA {
                _ = try runGit(["merge", "--ff-only", "@{u}"], in: repositoryURL)
                if autoCommitMessage != nil {
                    _ = try runGit(["push"], in: repositoryURL)
                }
                return result(
                    .pulledFastForward,
                    [autoCommitMessage, "Pulled upstream changes with a fast-forward merge.", autoCommitMessage == nil ? nil : "Pushed safe generated artifact commit."]
                        .compactMap { $0 }
                        .joined(separator: " ")
                )
            }

            if mergeBaseSHA == upstreamSHA {
                if autoCommitMessage != nil {
                    _ = try runGit(["push"], in: repositoryURL)
                    return result(
                        .upToDate,
                        [autoCommitMessage, "Pushed safe generated artifact commit. Already up to date."]
                            .compactMap { $0 }
                            .joined(separator: " ")
                    )
                }

                return result(.skippedLocalAhead, "Skipped because the local branch is ahead of upstream.")
            }

            guard canMergeCleanly(in: repositoryURL) else {
                return result(.skippedConflicts, "Skipped because upstream changes would conflict with local commits.")
            }

            do {
                _ = try runGit(["merge", "--no-edit", "@{u}"], in: repositoryURL)
                if autoCommitMessage != nil {
                    _ = try runGit(["push"], in: repositoryURL)
                }
                return result(
                    .pulledMerge,
                    [autoCommitMessage, "Pulled upstream changes with a clean merge commit.", autoCommitMessage == nil ? nil : "Pushed safe generated artifact commit."]
                        .compactMap { $0 }
                        .joined(separator: " ")
                )
            } catch {
                _ = try? runGit(["merge", "--abort"], in: repositoryURL)
                return result(.skippedConflicts, "Skipped because Git could not complete a clean merge.")
            }
        } catch {
            if (error as? RepositoryPullServiceError)?.isTimedOut == true {
                return result(.skippedTimedOut, error.localizedDescription)
            }

            return result(.failed, error.localizedDescription)
        }
    }

    private func hasMergeOrRebaseInProgress(in repositoryURL: URL) throws -> Bool {
        let gitDirectoryPath = try runGit(["rev-parse", "--git-dir"], in: repositoryURL).trimmedOutput
        let gitDirectoryURL: URL
        if gitDirectoryPath.hasPrefix("/") {
            gitDirectoryURL = URL(fileURLWithPath: gitDirectoryPath)
        } else {
            gitDirectoryURL = repositoryURL.appendingPathComponent(gitDirectoryPath)
        }

        return fileManager.fileExists(atPath: gitDirectoryURL.appendingPathComponent("MERGE_HEAD").path)
            || fileManager.fileExists(atPath: gitDirectoryURL.appendingPathComponent("rebase-apply").path)
            || fileManager.fileExists(atPath: gitDirectoryURL.appendingPathComponent("rebase-merge").path)
    }

    private func canMergeCleanly(in repositoryURL: URL) -> Bool {
        (try? runGit(["merge-tree", "--write-tree", "--quiet", "HEAD", "@{u}"], in: repositoryURL)) != nil
    }

    private func dirtyWorktreeStatus(in repositoryURL: URL) throws -> DirtyWorktreeStatus {
        let output = try runGit(["status", "--porcelain=v1", "-z"], in: repositoryURL).output
        let entries = DirtyWorktreeEntry.parse(output)
        return DirtyWorktreeStatus(entries: entries) { entry in
            isSafeAutoCommitEntry(entry)
        }
    }

    private func isSafeAutoCommitEntry(_ entry: DirtyWorktreeEntry) -> Bool {
        guard entry.originalPath == nil else {
            return false
        }

        let statusCharacters = Set(entry.status)
        guard statusCharacters.isDisjoint(with: ["D", "R", "C", "U"]) else {
            return false
        }

        let allowedStatusCharacters: Set<Character> = [" ", "?", "A", "M"]
        guard statusCharacters.isSubset(of: allowedStatusCharacters) else {
            return false
        }

        let pathExtension = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
        return safeAutoCommitExtensions.contains(pathExtension)
    }

    private func autoCommitSafeArtifacts(_ entries: [DirtyWorktreeEntry], in repositoryURL: URL) throws -> String {
        let paths = entries.map(\.path).sorted()
        _ = try runGit(["add", "--"] + paths, in: repositoryURL)
        _ = try runGit(["commit", "-m", "chore: save secondary machine artifacts"], in: repositoryURL)
        return "Committed \(paths.count) safe generated artifact file\(paths.count == 1 ? "" : "s") before pulling."
    }

    private func runGit(_ arguments: [String], in repositoryURL: URL) throws -> GitCommandResult {
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_MERGE_AUTOEDIT": "no",
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
            "GCM_INTERACTIVE": "Never",
            "LC_ALL": "C"
        ]) { _, new in new }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + commandTimeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if semaphore.wait(timeout: .now() + 5) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 5)
            }

            throw RepositoryPullServiceError.gitTimedOut(
                arguments: arguments,
                timeout: commandTimeout,
                result: GitCommandResult(status: process.terminationStatus, output: "", errorOutput: "")
            )
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let result = GitCommandResult(status: process.terminationStatus, output: output, errorOutput: errorOutput)

        guard process.terminationStatus == 0 else {
            throw RepositoryPullServiceError.gitFailed(arguments: arguments, result: result)
        }

        return result
    }
}

private struct DirtyWorktreeStatus {
    var entries: [DirtyWorktreeEntry]
    var canAutoCommit: Bool

    init(entries: [DirtyWorktreeEntry], isSafeEntry: (DirtyWorktreeEntry) -> Bool) {
        self.entries = entries
        self.canAutoCommit = !entries.isEmpty && entries.allSatisfy(isSafeEntry)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }
}

private struct DirtyWorktreeEntry: Equatable {
    var status: String
    var path: String
    var originalPath: String?

    static func parse(_ porcelainOutput: String) -> [DirtyWorktreeEntry] {
        let components = porcelainOutput.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [DirtyWorktreeEntry] = []
        var index = 0

        while index < components.count {
            let component = components[index]
            guard component.count >= 4 else {
                index += 1
                continue
            }

            let status = String(component.prefix(2))
            let path = String(component.dropFirst(3))

            if status.contains("R") || status.contains("C") {
                let originalPath = index + 1 < components.count ? components[index + 1] : nil
                entries.append(DirtyWorktreeEntry(status: status, path: path, originalPath: originalPath))
                index += 2
            } else {
                entries.append(DirtyWorktreeEntry(status: status, path: path, originalPath: nil))
                index += 1
            }
        }

        return entries
    }
}

private struct GitCommandResult: Equatable {
    var status: Int32
    var output: String
    var errorOutput: String

    var trimmedOutput: String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum RepositoryPullServiceError: LocalizedError {
    case gitFailed(arguments: [String], result: GitCommandResult)
    case gitTimedOut(arguments: [String], timeout: TimeInterval, result: GitCommandResult)

    var isTimedOut: Bool {
        switch self {
        case .gitTimedOut:
            true
        case .gitFailed:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case let .gitFailed(arguments, result):
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return "git \(arguments.joined(separator: " ")) failed with status \(result.status)."
            }

            return "git \(arguments.joined(separator: " ")) failed: \(message)"
        case let .gitTimedOut(arguments, timeout, result):
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = message.isEmpty ? "" : " Last error output: \(message)"
            return "Skipped because git \(arguments.joined(separator: " ")) did not finish within \(Int(timeout)) seconds.\(suffix)"
        }
    }
}
