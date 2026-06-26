import Foundation
import Testing
@testable import CodexKeepCore

@Suite(.serialized)
struct RepositoryPullServiceTests {
@Test func repositoryPullFastForwardsCleanRepositories() throws {
    let fixture = try RepositoryPullFixture()
    defer { fixture.cleanup() }

    try fixture.writePrimaryFile("README.md", "second\n")
    try fixture.git(["add", "README.md"], in: fixture.primary)
    try fixture.git(["commit", "-m", "second"], in: fixture.primary)
    try fixture.git(["push", "origin", "main"], in: fixture.primary)

    let result = RepositoryPullService(fileManager: fixture.fileManager).pullRepositories(
        repositoriesRoot: fixture.repositoriesRoot,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.results.map(\.status) == [.pulledFastForward])
    #expect(try String(contentsOf: fixture.secondary.appendingPathComponent("README.md"), encoding: .utf8) == "second\n")
}

@Test func repositoryPullSkipsDirtyRepositories() throws {
    let fixture = try RepositoryPullFixture()
    defer { fixture.cleanup() }

    try "local change\n".write(to: fixture.secondary.appendingPathComponent("worker.swift"), atomically: true, encoding: .utf8)
    try fixture.writePrimaryFile("REMOTE.md", "remote\n")
    try fixture.git(["add", "REMOTE.md"], in: fixture.primary)
    try fixture.git(["commit", "-m", "remote"], in: fixture.primary)
    try fixture.git(["push", "origin", "main"], in: fixture.primary)

    let result = RepositoryPullService(fileManager: fixture.fileManager).pullRepositories(
        repositoriesRoot: fixture.repositoriesRoot,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.results.map(\.status) == [.skippedDirty])
    #expect(!fixture.fileManager.fileExists(atPath: fixture.secondary.appendingPathComponent("REMOTE.md").path))
    #expect(try String(contentsOf: fixture.secondary.appendingPathComponent("worker.swift"), encoding: .utf8) == "local change\n")
}

@Test func repositoryPullCommitsAndPushesSafeGeneratedArtifacts() throws {
    let fixture = try RepositoryPullFixture()
    defer { fixture.cleanup() }

    try "state\n".write(to: fixture.secondary.appendingPathComponent("automation-state.md"), atomically: true, encoding: .utf8)
    try "value\n".write(to: fixture.secondary.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8)

    let result = RepositoryPullService(fileManager: fixture.fileManager).pullRepositories(
        repositoriesRoot: fixture.repositoriesRoot,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.results.map(\.status) == [.upToDate])
    #expect(result.results.first?.message.contains("Committed 2 safe generated artifact files") == true)
    #expect(result.results.first?.message.contains("Pushed safe generated artifact commit") == true)
    #expect(try fixture.git(["status", "--porcelain"], in: fixture.secondary) == "")

    try fixture.git(["fetch", "origin", "main"], in: fixture.primary)
    #expect(try fixture.git(["show", "origin/main:automation-state.md"], in: fixture.primary) == "state\n")
    #expect(try fixture.git(["show", "origin/main:metrics.csv"], in: fixture.primary) == "value\n")
}

@Test func repositoryPullCommitsSafeArtifactsThenMergesRemoteChanges() throws {
    let fixture = try RepositoryPullFixture()
    defer { fixture.cleanup() }

    try fixture.writePrimaryFile("REMOTE.md", "remote\n")
    try fixture.git(["add", "REMOTE.md"], in: fixture.primary)
    try fixture.git(["commit", "-m", "remote"], in: fixture.primary)
    try fixture.git(["push", "origin", "main"], in: fixture.primary)

    try "state\n".write(to: fixture.secondary.appendingPathComponent("automation-state.yml"), atomically: true, encoding: .utf8)

    let result = RepositoryPullService(fileManager: fixture.fileManager).pullRepositories(
        repositoriesRoot: fixture.repositoriesRoot,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.results.map(\.status) == [.pulledMerge])
    #expect(result.results.first?.message.contains("Committed 1 safe generated artifact file") == true)
    #expect(result.results.first?.message.contains("Pushed safe generated artifact commit") == true)
    #expect(fixture.fileManager.fileExists(atPath: fixture.secondary.appendingPathComponent("REMOTE.md").path))
    #expect(try fixture.git(["status", "--porcelain"], in: fixture.secondary) == "")

    try fixture.git(["fetch", "origin", "main"], in: fixture.primary)
    #expect(try fixture.git(["show", "origin/main:automation-state.yml"], in: fixture.primary) == "state\n")
    #expect(try fixture.git(["show", "origin/main:REMOTE.md"], in: fixture.primary) == "remote\n")
}

@Test func repositoryPullDoesNotAutoPushExistingLocalCommitsWithSafeArtifacts() throws {
    let fixture = try RepositoryPullFixture()
    defer { fixture.cleanup() }

    try "local commit\n".write(to: fixture.secondary.appendingPathComponent("LOCAL.md"), atomically: true, encoding: .utf8)
    try fixture.git(["add", "LOCAL.md"], in: fixture.secondary)
    try fixture.git(["commit", "-m", "local"], in: fixture.secondary)
    try "state\n".write(to: fixture.secondary.appendingPathComponent("automation-state.md"), atomically: true, encoding: .utf8)

    let result = RepositoryPullService(fileManager: fixture.fileManager).pullRepositories(
        repositoriesRoot: fixture.repositoriesRoot,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.results.map(\.status) == [.skippedLocalAhead])
    #expect(result.results.first?.message.contains("safe artifact auto-push would also push existing local commits") == true)
    #expect(try fixture.git(["status", "--porcelain"], in: fixture.secondary) == "?? automation-state.md\n")

    try fixture.git(["fetch", "origin", "main"], in: fixture.primary)
    #expect(throws: TestGitError.self) {
        try fixture.git(["show", "origin/main:LOCAL.md"], in: fixture.primary)
    }
    #expect(throws: TestGitError.self) {
        try fixture.git(["show", "origin/main:automation-state.md"], in: fixture.primary)
    }
}

@Test func repositoryPullMergesCleanDivergedRepositories() throws {
    let fixture = try RepositoryPullFixture()
    defer { fixture.cleanup() }

    try fixture.writePrimaryFile("REMOTE.md", "remote\n")
    try fixture.git(["add", "REMOTE.md"], in: fixture.primary)
    try fixture.git(["commit", "-m", "remote"], in: fixture.primary)
    try fixture.git(["push", "origin", "main"], in: fixture.primary)

    try "local\n".write(to: fixture.secondary.appendingPathComponent("LOCAL.md"), atomically: true, encoding: .utf8)
    try fixture.git(["add", "LOCAL.md"], in: fixture.secondary)
    try fixture.git(["commit", "-m", "local"], in: fixture.secondary)

    let result = RepositoryPullService(fileManager: fixture.fileManager).pullRepositories(
        repositoriesRoot: fixture.repositoriesRoot,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.results.map(\.status) == [.pulledMerge])
    #expect(fixture.fileManager.fileExists(atPath: fixture.secondary.appendingPathComponent("REMOTE.md").path))
    #expect(fixture.fileManager.fileExists(atPath: fixture.secondary.appendingPathComponent("LOCAL.md").path))
}

@Test func repositoryPullSkipsConflictingDivergedRepositoriesWithoutLeavingMergeState() throws {
    let fixture = try RepositoryPullFixture()
    defer { fixture.cleanup() }

    try fixture.writePrimaryFile("README.md", "remote\n")
    try fixture.git(["add", "README.md"], in: fixture.primary)
    try fixture.git(["commit", "-m", "remote"], in: fixture.primary)
    try fixture.git(["push", "origin", "main"], in: fixture.primary)

    try "local\n".write(to: fixture.secondary.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try fixture.git(["add", "README.md"], in: fixture.secondary)
    try fixture.git(["commit", "-m", "local"], in: fixture.secondary)

    let result = RepositoryPullService(fileManager: fixture.fileManager).pullRepositories(
        repositoriesRoot: fixture.repositoriesRoot,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(result.results.map(\.status) == [.skippedConflicts])
    #expect(try String(contentsOf: fixture.secondary.appendingPathComponent("README.md"), encoding: .utf8) == "local\n")
    #expect(!fixture.fileManager.fileExists(atPath: fixture.secondary.appending(relativePath: ".git/MERGE_HEAD").path))
}

@Test func repositoryPullTimesOutHungGitCommands() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let repositoriesRoot = root.appendingPathComponent("Repositories", isDirectory: true)
    let repository = repositoriesRoot.appendingPathComponent("hung-repo", isDirectory: true)
    let fakeGit = root.appendingPathComponent("git")

    try fileManager.createDirectory(at: repository.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
    try """
    #!/bin/sh
    exec sleep 10
    """.write(to: fakeGit, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)

    var progressMessages: [String] = []
    let result = RepositoryPullService(
        fileManager: fileManager,
        gitExecutableURL: fakeGit,
        commandTimeout: 0.1
    ).pullRepositories(repositoriesRoot: repositoriesRoot) { message in
        progressMessages.append(message)
    }

    #expect(result.results.map(\.status) == [.skippedTimedOut])
    #expect(progressMessages.contains("Checking hung-repo"))
    #expect(progressMessages.contains {
        $0.contains("hung-repo: skippedTimedOut")
    })
}
}

private final class RepositoryPullFixture {
    let fileManager = FileManager.default
    let root: URL
    let repositoriesRoot: URL
    let remote: URL
    let primary: URL
    let secondary: URL

    init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        repositoriesRoot = root.appendingPathComponent("Repositories", isDirectory: true)
        remote = root.appendingPathComponent("remote.git", isDirectory: true)
        primary = root.appendingPathComponent("primary", isDirectory: true)
        secondary = repositoriesRoot.appendingPathComponent("example", isDirectory: true)

        try fileManager.createDirectory(at: repositoriesRoot, withIntermediateDirectories: true)
        try git(["init", "--bare", remote.path], in: root)
        try git(["clone", remote.path, primary.path], in: root)
        try configureGitUser(in: primary)
        try writePrimaryFile("README.md", "initial\n")
        try git(["add", "README.md"], in: primary)
        try git(["commit", "-m", "initial"], in: primary)
        try git(["branch", "-M", "main"], in: primary)
        try git(["push", "-u", "origin", "main"], in: primary)
        try git(["clone", remote.path, secondary.path], in: repositoriesRoot)
        try configureGitUser(in: secondary)
    }

    func cleanup() {
        try? fileManager.removeItem(at: root)
    }

    func writePrimaryFile(_ relativePath: String, _ contents: String) throws {
        try contents.write(to: primary.appending(relativePath: relativePath), atomically: true, encoding: .utf8)
    }

    func configureGitUser(in repository: URL) throws {
        try git(["config", "user.email", "codex-keep@example.invalid"], in: repository)
        try git(["config", "user.name", "Codex Keep Tests"], in: repository)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C"
        ]) { _, new in new }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TestGitError(arguments: arguments, status: process.terminationStatus, output: output, errorOutput: errorOutput)
        }

        return output
    }
}

private struct TestGitError: LocalizedError {
    var arguments: [String]
    var status: Int32
    var output: String
    var errorOutput: String

    var errorDescription: String? {
        "git \(arguments.joined(separator: " ")) failed with status \(status): \(errorOutput)\(output)"
    }
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
