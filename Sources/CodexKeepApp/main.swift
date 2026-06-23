import AppKit
import CodexKeepCore
import ServiceManagement
import Sparkle
import SwiftUI

private enum CodexKeepAppError: LocalizedError {
    case backupTimedOut(String)

    var errorDescription: String? {
        switch self {
        case let .backupTimedOut(phase):
            "Backup timed out while \(phase)."
        }
    }
}

@MainActor
private func activateCodexKeepForModalUI() {
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in
            activateCodexKeepForModalUI()
        }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            activateCodexKeepForModalUI()
        }
    }
}

private extension CodexAppUpdateService.UpdateResult {
    var logMessage: String {
        switch self {
        case .skippedNotSecondary:
            "Codex app update skipped because Secondary Machine Mode is disabled."
        case .skippedCodexMissing:
            "Codex app update skipped because /Applications/Codex.app was not found."
        case let .skippedCodexBusy(reasons):
            "Codex app update skipped because Codex looks busy: \(reasons.joined(separator: " | "))"
        case .skippedAlreadyRunning:
            "Codex app update skipped because an update check is already running or already ran today."
        case let .started(currentVersion, feedURL):
            "Codex app update check started from version \(currentVersion) using \(feedURL)."
        case let .failed(message):
            "Codex app update failed to start: \(message)"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settingsStore = SettingsStore()
    private let backupService = BackupService()
    private let deployService = DeployService()
    private let peerSyncService = PeerSyncService()
    private let automationMoveService = AutomationMoveService()
    private let codexAppUpdateService = CodexAppUpdateService()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private let sparkleUserDriverDelegate = SparkleUserDriverDelegate()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: sparkleUserDriverDelegate
    )

    private var timer: Timer?
    private var repositoryPullTimer: Timer?
    private var codexAppUpdateTimer: Timer?
    private var animationTimer: Timer?
    private var backupTimeoutTimer: Timer?
    private var trustedMachinesWindowController: NSWindowController?
    private var manageAutomationsWindowController: NSWindowController?
    private var peerSyncReviewWindowController: NSWindowController?
    private var lastResult: BackupResult?
    private var lastPeerSyncResult: PeerSyncApplyResult?
    private var lastError: Error?
    private weak var statusMenuItem: NSMenuItem?
    private var isBackingUp = false
    private var isPullingRepositories = false
    private var activeBackupID: UUID?
    private var currentBackupPhase = "starting backup"
    private var animationFrame = 0
    private let animationFrames = ["|", "/", "-", "\\"]
    private let minimumSyncIndicatorDuration: TimeInterval = 1.25
    private let backupTimeoutDuration: TimeInterval = 180
    private let repositoryPullIntervalDuration: TimeInterval = 30 * 60
    private let codexAppUpdateHour = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        rebuildMenu()
        runBackup()
        scheduleTimer()
        scheduleRepositoryPullTimer()
        scheduleCodexAppUpdateTimer()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: "Codex Keep")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = "Codex Keep"
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(max(settingsStore.settings.backupIntervalMinutes, 5) * 60),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.runBackup()
            }
        }
    }

    private func scheduleRepositoryPullTimer() {
        repositoryPullTimer?.invalidate()
        repositoryPullTimer = nil

        guard settingsStore.settings.secondaryMachineMode else {
            return
        }

        repositoryPullTimer = Timer.scheduledTimer(
            withTimeInterval: repositoryPullIntervalDuration,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.runRepositoryPull()
            }
        }
    }

    private func scheduleCodexAppUpdateTimer(now: Date = Date()) {
        codexAppUpdateTimer?.invalidate()
        codexAppUpdateTimer = nil

        guard settingsStore.settings.secondaryMachineMode else {
            return
        }

        let fireDate = nextCodexAppUpdateDate(after: now)
        let timer = Timer(
            fireAt: fireDate,
            interval: 0,
            target: self,
            selector: #selector(codexAppUpdateTimerFired),
            userInfo: nil,
            repeats: false
        )
        timer.tolerance = 15 * 60
        RunLoop.main.add(timer, forMode: .common)
        codexAppUpdateTimer = timer
        Self.logCodexAppUpdateLine("Next daily Codex app update scheduled for \(fireDate)")
    }

    private func nextCodexAppUpdateDate(after date: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(
            bySettingHour: codexAppUpdateHour,
            minute: 0,
            second: 0,
            of: date
        ) ?? date

        if today > date {
            return today
        }

        return calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: statusTitle(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "Back Up Now", action: #selector(backUpNow), keyEquivalent: "b"))
        menu.addItem(actionItem(title: "Review Peer Changes...", action: #selector(reviewPeerChanges), keyEquivalent: "r"))
        menu.addItem(actionItem(title: "Open Backup Folder", action: #selector(openBackupFolder), keyEquivalent: "o"))
        menu.addItem(actionItem(title: "Open Diagnostic Log", action: #selector(openDiagnosticLog), keyEquivalent: "l"))
        menu.addItem(actionItem(title: "Deploy Backup to This Mac...", action: #selector(deployBackupToThisMac), keyEquivalent: "d"))
        menu.addItem(actionItem(title: "Trusted Machines...", action: #selector(configureTrustedMachines), keyEquivalent: "t"))
        menu.addItem(actionItem(title: "Manage Automations...", action: #selector(manageAutomations), keyEquivalent: "m"))
        menu.addItem(autoSyncItem())
        menu.addItem(repositoryDevFilesItem())
        menu.addItem(secondaryMachineModeItem())
        let pullRepositoriesItem = actionItem(title: "Pull Repositories Now", action: #selector(pullRepositoriesNow), keyEquivalent: "p")
        pullRepositoriesItem.isEnabled = !isPullingRepositories
        menu.addItem(pullRepositoriesItem)
        menu.addItem(actionItem(title: "Open Repository Pull Log", action: #selector(openRepositoryPullLog), keyEquivalent: "g"))
        menu.addItem(actionItem(title: "Update Codex App Now", action: #selector(updateCodexAppNow), keyEquivalent: ""))
        menu.addItem(actionItem(title: "Open Codex App Update Log", action: #selector(openCodexAppUpdateLog), keyEquivalent: ""))
        menu.addItem(actionItem(title: "Choose Backup Folder...", action: #selector(chooseBackupFolder), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem())
        menu.addItem(actionItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u"))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit Codex Keep", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusMenuItem?.title = statusTitle()
    }

    private func actionItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func launchAtLoginItem() -> NSMenuItem {
        let item = actionItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = isLaunchAtLoginEnabled ? .on : .off
        return item
    }

    private func autoSyncItem() -> NSMenuItem {
        let item = actionItem(title: "Auto-sync Trusted Machines", action: #selector(toggleAutoSync), keyEquivalent: "")
        item.state = settingsStore.settings.automaticallySyncTrustedMachines ? .on : .off
        return item
    }

    private func repositoryDevFilesItem() -> NSMenuItem {
        let item = actionItem(title: "Sync Local Repo Dev Files", action: #selector(toggleRepositoryDevFiles), keyEquivalent: "")
        item.state = settingsStore.settings.syncRepositoryDevFiles ? .on : .off
        return item
    }

    private func secondaryMachineModeItem() -> NSMenuItem {
        let item = actionItem(title: "Secondary Machine Mode", action: #selector(toggleSecondaryMachineMode), keyEquivalent: "")
        item.state = settingsStore.settings.secondaryMachineMode ? .on : .off
        return item
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func statusTitle() -> String {
        if isBackingUp {
            return "Saving: \(currentBackupPhase)"
        }

        if isPullingRepositories {
            return "Pulling repositories"
        }

        if let result = lastResult {
            if let lastPeerSyncResult {
                let peerSummary = peerSyncStatusSummary(lastPeerSyncResult)
                if !peerSummary.isEmpty {
                    return "\(peerSummary) \(relativeSyncTime(since: result.manifest.createdAt))"
                }
            }

            return "Last synced \(relativeSyncTime(since: result.manifest.createdAt))"
        }

        if let lastError {
            return "Backup failed: \(lastError.localizedDescription)"
        }

        return "Codex Keep is ready"
    }

    private func peerSyncStatusSummary(_ result: PeerSyncApplyResult) -> String {
        if result.appliedItemCount > 0, result.skippedItemCount > 0 {
            return "Synced \(result.appliedItemCount), skipped \(result.skippedItemCount) peer files"
        }

        if result.appliedItemCount > 0 {
            return "Last synced \(result.appliedItemCount) peer files"
        }

        if result.skippedItemCount > 0 {
            return "Skipped \(result.skippedItemCount) peer files still downloading"
        }

        return ""
    }

    private func relativeSyncTime(since date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 {
            return "just now"
        }

        return relativeDateFormatter.localizedString(for: date, relativeTo: now)
    }

    @objc private func backUpNow() {
        runBackup()
    }

    @objc private func openBackupFolder() {
        let destinationURL = URL(fileURLWithPath: settingsStore.settings.destinationRootPath)
        NSWorkspace.shared.open(destinationURL)
    }

    @objc private func openDiagnosticLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.backupRunLogURL()])
    }

    @objc private func openRepositoryPullLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.repositoryPullLogURL()])
    }

    @objc private func openCodexAppUpdateLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.codexAppUpdateLogURL()])
    }

    @objc private func reviewPeerChanges() {
        do {
            let backupResult = try BackupService().runBackup(settings: settingsStore.settings)
            try settingsStore.update { settings in
                settings = peerSyncService.settingsByRecordingLocalState(
                    settings,
                    localManifest: backupResult.manifest
                )
            }

            let refreshedBackupResult = try BackupService().runBackup(settings: settingsStore.settings)
            let plans = try peerSyncService.makePlans(
                settings: settingsStore.settings,
                localManifest: refreshedBackupResult.manifest
            )
            guard let selectedItemIDs = presentPeerSyncPlans(plans) else {
                return
            }

            let result = try peerSyncService.apply(
                plans: plans,
                selectedItemIDs: selectedItemIDs,
                settings: settingsStore.settings
            )
            try settingsStore.update { settings in
                settings = result.updatedSettings
            }
            lastPeerSyncResult = result
            lastResult = try BackupService().runBackup(settings: settingsStore.settings)
            presentPeerSyncSuccess(result)
        } catch {
            lastError = error
            presentError(error, messageText: "Codex Keep could not sync peer changes.")
        }

        rebuildMenu()
    }

    @objc private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Keep Backup Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settingsStore.settings.destinationRootPath)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try settingsStore.update { settings in
                settings.destinationRootPath = url.path
            }
            runBackup()
        } catch {
            lastError = error
            lastResult = nil
            presentError(error)
        }

        rebuildMenu()
    }

    @objc private func configureTrustedMachines() {
        let availablePeers = peerSyncService.availablePeerMachineNames(settings: settingsStore.settings)
        let view = TrustedMachinesView(
            machineNames: availablePeers,
            selectedMachineNames: settingsStore.settings.trustedMachineNames,
            backupFolderPath: settingsStore.settings.destinationRootPath,
            currentMachineName: Machine.currentName(),
            onSelectionChange: { [weak self] selectedMachineNames in
                Task { @MainActor in
                    self?.saveTrustedMachineSelection(selectedMachineNames)
                }
            },
            onOpenBackupFolder: { [weak self] in
                guard let self else {
                    return
                }

                NSWorkspace.shared.open(URL(fileURLWithPath: self.settingsStore.settings.destinationRootPath))
            }
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Trusted Machines"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: availablePeers.isEmpty ? 300 : min(520, 238 + availablePeers.count * 54)))
        window.center()

        let controller = NSWindowController(window: window)
        trustedMachinesWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func deployBackupToThisMac() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Keep Backup"
        panel.prompt = "Review"
        panel.message = "Choose a Codex Keep latest or snapshot folder, or choose a machine folder to use its latest backup."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settingsStore.settings.destinationRootPath)

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        do {
            let sourceURL = normalizedBackupSourceURL(from: selectedURL)
            let plan = try deployService.makePlan(sourceURL: sourceURL)
            guard let selectedItemIDs = presentDeployPlan(plan) else {
                return
            }

            let result = try deployService.deploy(
                plan: plan,
                selectedItemIDs: selectedItemIDs,
                settings: settingsStore.settings
            )
            presentDeploySuccess(result)
        } catch {
            lastError = error
            presentError(error, messageText: "Codex Keep could not deploy the backup.")
        }
    }

    @objc private func manageAutomations() {
        do {
            let automations = try automationMoveService.localAutomations()
            let pendingMoves = try automationMoveService.pendingMoves(settings: settingsStore.settings)
            let targetMachineNames = settingsStore.settings.trustedMachineNames.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            let view = ManageAutomationsView(
                automations: automations,
                pendingMoves: pendingMoves,
                targetMachineNames: targetMachineNames,
                currentMachineName: Machine.currentName(),
                backupFolderPath: settingsStore.settings.destinationRootPath,
                onMove: { [weak self] selectedIDs, targetMachineName in
                    Task { @MainActor in
                        self?.moveAutomations(selectedIDs, to: targetMachineName)
                    }
                },
                onConfigureTrustedMachines: { [weak self] in
                    Task { @MainActor in
                        self?.configureTrustedMachines()
                    }
                },
                onInstallIncomingMoves: { [weak self] in
                    Task { @MainActor in
                        self?.installIncomingAutomationMoves()
                    }
                },
                onOpenBackupFolder: { [weak self] in
                    guard let self else {
                        return
                    }

                    NSWorkspace.shared.open(URL(fileURLWithPath: self.settingsStore.settings.destinationRootPath))
                }
            )
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Manage Automations"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 660, height: min(680, 360 + automations.count * 54 + pendingMoves.count * 62)))
            window.center()

            let controller = NSWindowController(window: window)
            manageAutomationsWindowController = controller
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            lastError = error
            presentError(error, messageText: "Codex Keep could not load automations.")
        }
    }

    private func moveAutomations(_ selectedIDs: Set<String>, to targetMachineName: String) {
        do {
            let result = try automationMoveService.moveAutomations(
                ids: selectedIDs,
                to: targetMachineName,
                settings: settingsStore.settings
            )
            lastResult = try BackupService().runBackup(settings: settingsStore.settings)
            manageAutomationsWindowController?.close()
            manageAutomationsWindowController = nil
            presentAutomationMoveSuccess(result, targetMachineName: targetMachineName)
        } catch {
            lastError = error
            presentError(error, messageText: "Codex Keep could not move automations.")
        }

        rebuildMenu()
    }

    private func installIncomingAutomationMoves() {
        do {
            let result = try automationMoveService.consumePendingMoves(settings: settingsStore.settings)
            lastResult = try BackupService().runBackup(settings: settingsStore.settings)
            manageAutomationsWindowController?.close()
            manageAutomationsWindowController = nil
            presentAutomationMoveInstallSuccess(result)
        } catch {
            lastError = error
            presentError(error, messageText: "Codex Keep could not install automation moves.")
        }

        rebuildMenu()
    }

    @objc private func checkForUpdates() {
        activateCodexKeepForModalUI()
        updaterController.checkForUpdates(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = error
            presentError(error, messageText: "Codex Keep could not update Launch at Login.")
        }

        rebuildMenu()
    }

    private func saveTrustedMachineSelection(_ selectedMachineNames: Set<String>) {
        do {
            try settingsStore.update { settings in
                settings.trustedMachineNames = selectedMachineNames
                if selectedMachineNames.isEmpty {
                    settings.automaticallySyncTrustedMachines = false
                }
            }
        } catch {
            lastError = error
            presentError(error, messageText: "Codex Keep could not save trusted machines.")
        }

        rebuildMenu()
    }

    @objc private func toggleAutoSync() {
        if settingsStore.settings.trustedMachineNames.isEmpty,
           !settingsStore.settings.automaticallySyncTrustedMachines {
            configureTrustedMachines()
            return
        }

        do {
            try settingsStore.update { settings in
                settings.automaticallySyncTrustedMachines.toggle()
            }
        } catch {
            lastError = error
            presentError(error, messageText: "Codex Keep could not update auto-sync.")
        }

        rebuildMenu()
    }

    @objc private func toggleRepositoryDevFiles() {
        if !settingsStore.settings.syncRepositoryDevFiles {
            let alert = NSAlert()
            alert.messageText = "Sync local repo dev files?"
            alert.informativeText = "Codex Keep will back up and sync root .env files for Git repositories that exist on both trusted Macs. Repositories that do not exist locally on another Mac are skipped."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        do {
            try settingsStore.update { settings in
                settings.syncRepositoryDevFiles.toggle()
            }
            runBackup()
        } catch {
            presentError(error, messageText: "Codex Keep could not update local repo dev file sync.")
        }

        rebuildMenu()
    }

    @objc private func toggleSecondaryMachineMode() {
        if !settingsStore.settings.secondaryMachineMode {
            let alert = NSAlert()
            alert.messageText = "Enable Secondary Machine Mode?"
            alert.informativeText = "Every 30 minutes, Codex Keep will pull clean Git repositories in ~/Repositories. Repositories with uncommitted changes, missing upstreams, or merge conflicts are skipped and logged."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        do {
            var isEnabling = false
            try settingsStore.update { settings in
                settings.secondaryMachineMode.toggle()
                isEnabling = settings.secondaryMachineMode
            }
            scheduleRepositoryPullTimer()
            scheduleCodexAppUpdateTimer()
            if isEnabling {
                runRepositoryPull()
            }
        } catch {
            presentError(error, messageText: "Codex Keep could not update Secondary Machine Mode.")
        }

        rebuildMenu()
    }

    @objc private func pullRepositoriesNow() {
        runRepositoryPull()
    }

    @objc private func updateCodexAppNow() {
        let result = runCodexAppUpdate(force: true)
        switch result {
        case .started:
            break
        case .skippedCodexBusy, .skippedCodexMissing, .failed:
            presentCodexAppUpdateResult(result)
        case .skippedNotSecondary, .skippedAlreadyRunning:
            break
        }
        rebuildMenu()
    }

    @objc private func codexAppUpdateTimerFired() {
        _ = runCodexAppUpdate(force: false)
        scheduleCodexAppUpdateTimer()
        rebuildMenu()
    }

    private func runCodexAppUpdate(force: Bool) -> CodexAppUpdateService.UpdateResult {
        let result: CodexAppUpdateService.UpdateResult
        if force {
            result = codexAppUpdateService.runUpdate(
                isBackingUp: isBackingUp,
                isPullingRepositories: isPullingRepositories,
                log: Self.logCodexAppUpdateLine
            )
        } else {
            result = codexAppUpdateService.runDailyUpdateIfNeeded(
                settings: settingsStore.settings,
                isBackingUp: isBackingUp,
                isPullingRepositories: isPullingRepositories,
                log: Self.logCodexAppUpdateLine
            )
        }

        Self.logCodexAppUpdateLine(result.logMessage)
        return result
    }

    private func presentCodexAppUpdateResult(_ result: CodexAppUpdateService.UpdateResult) {
        let alert = NSAlert()
        alert.messageText = "Codex app update did not start"
        alert.informativeText = result.logMessage
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Update Log")

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Self.codexAppUpdateLogURL())
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func runRepositoryPull() {
        guard !isPullingRepositories else {
            return
        }

        isPullingRepositories = true
        if !isBackingUp {
            updateStatusItemForRepositoryPull()
        }
        rebuildMenu()

        Task.detached {
            Self.resetRepositoryPullLog()
            Self.logRepositoryPullLine("Repository pull started with Codex Keep \(Self.appVersionDescription())")
            let repositoriesRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Repositories", isDirectory: true)
            let result = RepositoryPullService().pullRepositories(repositoriesRoot: repositoriesRoot) { message in
                Self.logRepositoryPullLine(message)
            }
            Self.writeRepositoryPullLog(result)

            await MainActor.run {
                self.isPullingRepositories = false
                if !self.isBackingUp {
                    self.restoreDefaultStatusItem()
                }
                self.rebuildMenu()
            }
        }
    }

    private func runBackup() {
        guard !isBackingUp else {
            return
        }

        isBackingUp = true
        let backupID = UUID()
        activeBackupID = backupID
        currentBackupPhase = "starting backup"
        lastError = nil
        startSyncAnimation()
        scheduleBackupTimeout(for: backupID)
        rebuildMenu()

        let settings = settingsStore.settings
        let startedAt = Date()
        let minimumSyncIndicatorDuration = minimumSyncIndicatorDuration

        Task.detached {
            Self.resetBackupRunLog()
            Self.logBackupPhase("Backup run started with Codex Keep \(Self.appVersionDescription())")
            let result = Result {
                try Self.runBackupAndPeerSync(settings: settings)
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            let remaining = minimumSyncIndicatorDuration - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }

            await MainActor.run {
                guard self.activeBackupID == backupID else {
                    return
                }

                self.backupTimeoutTimer?.invalidate()
                self.backupTimeoutTimer = nil
                self.activeBackupID = nil
                self.stopSyncAnimation()
                self.isBackingUp = false

                switch result {
                case let .success(syncRunResult):
                    if syncRunResult.updatedSettings != self.settingsStore.settings {
                        do {
                            try self.settingsStore.update { settings in
                                settings = syncRunResult.updatedSettings
                            }
                        } catch {
                            self.lastError = error
                            self.lastResult = nil
                            self.presentError(error)
                            self.rebuildMenu()
                            return
                        }
                    }

                    self.lastResult = syncRunResult.backupResult
                    self.lastPeerSyncResult = syncRunResult.peerSyncResult
                    self.lastError = nil
                case let .failure(error):
                    self.lastError = error
                    self.lastResult = nil
                    self.lastPeerSyncResult = nil
                    self.presentError(error)
                }

                self.rebuildMenu()
            }
        }
    }

    private func scheduleBackupTimeout(for backupID: UUID) {
        backupTimeoutTimer?.invalidate()
        backupTimeoutTimer = Timer.scheduledTimer(withTimeInterval: backupTimeoutDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleBackupTimeout(for: backupID)
            }
        }
    }

    private func handleBackupTimeout(for backupID: UUID) {
        guard activeBackupID == backupID, isBackingUp else {
            return
        }

        let phase = Self.lastBackupLogPhase() ?? currentBackupPhase
        activeBackupID = nil
        backupTimeoutTimer?.invalidate()
        backupTimeoutTimer = nil
        stopSyncAnimation()
        isBackingUp = false
        lastResult = nil
        lastPeerSyncResult = nil
        lastError = CodexKeepAppError.backupTimedOut(phase)
        presentError(lastError!, messageText: "Codex Keep is taking too long to finish the backup.")
        rebuildMenu()
    }

    private func startSyncAnimation() {
        animationFrame = 0
        updateStatusItemForSync()
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceSyncAnimation()
            }
        }
    }

    private func advanceSyncAnimation() {
        animationFrame = (animationFrame + 1) % animationFrames.count
        currentBackupPhase = Self.lastBackupLogPhase() ?? currentBackupPhase
        statusMenuItem?.title = statusTitle()
        updateStatusItemForSync()
    }

    private func stopSyncAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        restoreDefaultStatusItem()
    }

    private func restoreDefaultStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: "Codex Keep")
            button.image?.isTemplate = true
            button.title = "Codex Keep"
        }
    }

    private func updateStatusItemForSync() {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Backing up")
        button.image?.isTemplate = true
        button.title = "Saving \(animationFrames[animationFrame])"
    }

    private func updateStatusItemForRepositoryPull() {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Pulling repositories")
        button.image?.isTemplate = true
        button.title = "Pulling"
    }

    private func presentError(_ error: Error, messageText: String = "Codex Keep could not finish the backup.") {
        let alert = NSAlert(error: error)
        alert.messageText = messageText
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func normalizedBackupSourceURL(from selectedURL: URL) -> URL {
        let manifestURL = selectedURL.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return selectedURL
        }

        let latestURL = selectedURL.appendingPathComponent("latest", isDirectory: true)
        let latestManifestURL = latestURL.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: latestManifestURL.path) {
            return latestURL
        }

        return selectedURL
    }

    private func presentDeployPlan(_ plan: DeployPlan) -> Set<String>? {
        let alert = NSAlert()
        alert.messageText = "Deploy \(plan.manifest.machineName) backup?"
        alert.informativeText = deployPlanSummary(plan)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Deploy")
        alert.addButton(withTitle: "Cancel")

        let checklist = deployChecklistView(for: plan)
        alert.accessoryView = checklist.view

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let selectedIDs = Set(checklist.checkboxes.compactMap { id, checkbox in
            checkbox.state == .on ? id : nil
        })

        if selectedIDs.isEmpty {
            presentError(
                DeployServiceError.noSelectedItems,
                messageText: "Codex Keep could not deploy the backup."
            )
            return nil
        }

        return selectedIDs
    }

    private func deployChecklistView(for plan: DeployPlan) -> (view: NSView, checkboxes: [(String, NSButton)]) {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        var checkboxes: [(String, NSButton)] = []

        for item in plan.items where item.status != .missingFromBackup {
            let checkbox = NSButton(checkboxWithTitle: deployCheckboxTitle(for: item), target: nil, action: nil)
            checkbox.state = item.status == .unchanged ? .off : .on
            checkbox.toolTip = item.targetPath
            checkbox.lineBreakMode = .byTruncatingMiddle
            checkbox.widthAnchor.constraint(lessThanOrEqualToConstant: 540).isActive = true
            checkboxes.append((item.id, checkbox))
            stackView.addArrangedSubview(checkbox)
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: 560).isActive = true
        let checklistHeight = CGFloat(min(340, max(120, plan.items.count * 26)))
        scrollView.heightAnchor.constraint(equalToConstant: checklistHeight).isActive = true

        return (scrollView, checkboxes)
    }

    private func deployCheckboxTitle(for item: DeployPlanItem) -> String {
        let status: String
        switch item.status {
        case .new:
            status = "new"
        case .changed:
            status = "changed"
        case .unchanged:
            status = "unchanged"
        case .missingFromBackup:
            status = "missing"
        }

        return "\(item.displayName) (\(status), \(item.fileCount) files)"
    }

    private func deployPlanSummary(_ plan: DeployPlan) -> String {
        var lines = [
            "Created \(relativeSyncTime(since: plan.manifest.createdAt)). \(plan.changedItemCount) items will be selected by default; \(plan.unchangedItemCount) unchanged items are left unchecked.",
            "Codex Keep will save a safety snapshot of the selected local items before replacing them."
        ]

        if !plan.warnings.isEmpty {
            lines.append("Backup warnings: \(plan.warnings.joined(separator: " "))")
        }

        return lines.joined(separator: "\n\n")
    }

    private func presentPeerSyncPlans(_ plans: [PeerSyncPlan]) -> Set<String>? {
        let visibleItems = plans.flatMap { plan in
            plan.items.filter { item in
                switch item.status {
                case .incomingNew, .incomingChanged, .conflict, .peerDeletedReviewRequired:
                    return true
                case .unchanged, .localChanged:
                    return false
                }
            }
        }
        let selectableItems = visibleItems.filter { isSelectablePeerSyncItem($0) }

        if visibleItems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No peer changes to sync"
            alert.informativeText = peerSyncPlanSummary(plans)
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }

        activateCodexKeepForModalUI()

        var selectedIDs: Set<String>?
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = selectableItems.isEmpty ? "Peer Changes Need Review" : "Sync Peer Changes"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: PeerSyncReviewView(
            items: visibleItems,
            incomingCount: plans.reduce(0) { $0 + $1.incomingItemCount },
            reviewCount: plans.reduce(0) { $0 + $1.reviewItemCount },
            localChangedCount: plans.flatMap(\.items).filter { $0.status == .localChanged }.count,
            warnings: plans.flatMap(\.warnings),
            onCancel: {
                NSApp.stopModal()
                window.close()
            },
            onSync: { ids in
                selectedIDs = ids
                NSApp.stopModal()
                window.close()
            }
        ))

        let controller = NSWindowController(window: window)
        peerSyncReviewWindowController = controller
        controller.showWindow(nil)
        NSApp.runModal(for: window)
        peerSyncReviewWindowController = nil

        guard let selectedIDs else {
            return nil
        }

        if selectedIDs.isEmpty {
            presentError(
                PeerSyncServiceError.noSelectedItems,
                messageText: "Codex Keep could not sync peer changes."
            )
            return nil
        }

        return selectedIDs
    }

    private func isSelectablePeerSyncItem(_ item: PeerSyncPlanItem) -> Bool {
        switch item.status {
        case .incomingNew, .incomingChanged, .peerDeletedReviewRequired:
            return true
        case .conflict:
            return item.peerSHA256 != nil
        case .unchanged, .localChanged:
            return false
        }
    }

    private func peerSyncPlanSummary(_ plans: [PeerSyncPlan]) -> String {
        let incoming = plans.reduce(0) { $0 + $1.incomingItemCount }
        let review = plans.reduce(0) { $0 + $1.reviewItemCount }
        let localChanged = plans.flatMap(\.items).filter { $0.status == .localChanged }.count
        var lines = [
            "\(incoming) non-conflicting peer files are selected by default. \(review) conflicts or deletions need review."
        ]

        if localChanged > 0 {
            lines.append("\(localChanged) files changed locally and will be left for the peer Mac to pull.")
        }

        let warnings = plans.flatMap(\.warnings)
        if !warnings.isEmpty {
            lines.append("Backup warnings: \(warnings.joined(separator: " "))")
        }

        lines.append("Codex Keep saves a sync safety snapshot before changing or deleting local files.")
        return lines.joined(separator: "\n\n")
    }

    private func presentDeploySuccess(_ result: DeployResult) {
        let alert = NSAlert()
        alert.messageText = "Backup deployed"
        alert.informativeText = "\(result.deployedItemCount) items were deployed. Safety snapshot: \(result.safetySnapshotURL.path)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Safety Snapshot")

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(result.safetySnapshotURL)
        }
    }

    private func presentPeerSyncSuccess(_ result: PeerSyncApplyResult) {
        let alert = NSAlert()
        alert.messageText = "Peer changes synced"
        let skippedText = result.skippedItemCount > 0
            ? ", \(result.skippedItemCount) files still downloading skipped"
            : ""
        alert.informativeText = "\(result.appliedItemCount) files updated, \(result.conflictCopyCount) conflict copies saved, \(result.deletedItemCount) files deleted\(skippedText). Safety snapshot: \(result.safetySnapshotURL.path)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Safety Snapshot")

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(result.safetySnapshotURL)
        }
    }

    private func presentAutomationMoveSuccess(_ result: AutomationMoveResult, targetMachineName: String) {
        let alert = NSAlert()
        alert.messageText = "Automations moved"
        alert.informativeText = "\(result.movedCount) automations were prepared for \(targetMachineName). They will be installed automatically the next time Codex Keep backs up on that Mac. Safety snapshot: \(result.safetySnapshotURL.path)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Safety Snapshot")

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(result.safetySnapshotURL)
        }
    }

    private func presentAutomationMoveInstallSuccess(_ result: AutomationMoveConsumeResult) {
        let alert = NSAlert()
        alert.messageText = "Automation moves installed"
        var lines = [
            "\(result.installedCount) automations were installed from \(result.consumedMoveCount) incoming move packages."
        ]

        if let safetySnapshotURL = result.safetySnapshotURL {
            lines.append("Safety snapshot: \(safetySnapshotURL.path)")
        }

        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")

        if let safetySnapshotURL = result.safetySnapshotURL {
            alert.addButton(withTitle: "Open Safety Snapshot")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(safetySnapshotURL)
            }
        } else {
            alert.runModal()
        }
    }

    nonisolated private static func runBackupAndPeerSync(settings: BackupSettings) throws -> BackupAndPeerSyncResult {
        let backupService = BackupService()
        let peerSyncService = PeerSyncService()
        let automationMoveService = AutomationMoveService()
        var workingSettings = settings
        logBackupPhase("Checking pending automation moves")
        let automationMoveResult = try automationMoveService.consumePendingMoves(settings: workingSettings)
        if automationMoveResult.installedCount > 0 {
            logBackupPhase("Installed \(automationMoveResult.installedCount) automation moves from \(automationMoveResult.consumedMoveCount) packages")
        } else {
            logBackupPhase("No pending automation moves installed")
        }
        logBackupPhase("Running local backup")
        var backupResult = try backupService.runBackup(settings: workingSettings)

        logBackupPhase("Recording local sync state")
        let settingsAfterLocalState = peerSyncService.settingsByRecordingLocalState(
            workingSettings,
            localManifest: backupResult.manifest
        )
        if settingsAfterLocalState != workingSettings {
            workingSettings = settingsAfterLocalState
            logBackupPhase("Refreshing backup after local sync state changed")
            backupResult = try backupService.runBackup(settings: workingSettings)
        }

        var peerSyncResult: PeerSyncApplyResult?
        if workingSettings.automaticallySyncTrustedMachines,
           !workingSettings.trustedMachineNames.isEmpty {
            logBackupPhase("Planning trusted-machine sync")
            let plans = try peerSyncService.makePlans(
                settings: workingSettings,
                localManifest: backupResult.manifest
            )
            if plans.isEmpty {
                logBackupPhase("No trusted peer manifests were ready for sync")
            }
            workingSettings = peerSyncService.settingsByRecordingUnchangedPeerFiles(
                workingSettings,
                plans: plans
            )

            let automaticItemIDs = Set(plans.flatMap(\.automaticItemIDs))
            if !automaticItemIDs.isEmpty {
                logBackupPhase("Applying \(automaticItemIDs.count) automatic peer sync items")
                let applied = try peerSyncService.apply(
                    plans: plans,
                    selectedItemIDs: automaticItemIDs,
                    settings: workingSettings
                )
                workingSettings = applied.updatedSettings
                peerSyncResult = applied
                if applied.skippedItemCount > 0 {
                    let skippedPaths = applied.skippedBackupRelativePaths.prefix(12).joined(separator: ", ")
                    let remainingCount = max(applied.skippedBackupRelativePaths.count - 12, 0)
                    let suffix = remainingCount > 0 ? ", +\(remainingCount) more" : ""
                    logBackupPhase("Skipped \(applied.skippedItemCount) peer sync items still downloading: \(skippedPaths)\(suffix)")
                }
                logBackupPhase("Refreshing backup after peer sync")
                backupResult = try backupService.runBackup(settings: workingSettings)
            } else if workingSettings != settingsAfterLocalState {
                logBackupPhase("Refreshing backup after unchanged peer files")
                backupResult = try backupService.runBackup(settings: workingSettings)
            }
        }

        logBackupPhase("Backup run finished")
        return BackupAndPeerSyncResult(
            backupResult: backupResult,
            peerSyncResult: peerSyncResult,
            updatedSettings: workingSettings
        )
    }

    nonisolated private static func resetBackupRunLog() {
        let url = backupRunLogURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func logBackupPhase(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let url = backupRunLogURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static func backupRunLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Codex Keep", isDirectory: true)
            .appendingPathComponent("last-run.log")
    }

    nonisolated private static func resetRepositoryPullLog() {
        let url = repositoryPullLogURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func logRepositoryPullLine(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        appendRepositoryPullLog(line)
    }

    nonisolated private static func writeRepositoryPullLog(_ result: RepositoryPullRunResult) {
        let formatter = ISO8601DateFormatter()
        let summary = "Pulled \(result.pulledCount), skipped \(result.skippedCount), failed \(result.failedCount) of \(result.results.count) repositories"
        var lines = [
            "\(formatter.string(from: Date())) \(summary)",
            "Repositories root: \(result.repositoriesRootPath)",
            "Started: \(formatter.string(from: result.startedAt))",
            "Finished: \(formatter.string(from: result.finishedAt))"
        ]

        if result.results.isEmpty {
            lines.append("No Git repositories were found.")
        } else {
            lines.append("")
            for item in result.results {
                lines.append("[\(item.status.rawValue)] \(item.repositoryName): \(item.message)")
                lines.append("  \(item.repositoryPath)")
            }
        }

        appendRepositoryPullLog(lines.joined(separator: "\n") + "\n")
    }

    nonisolated private static func appendRepositoryPullLog(_ text: String) {
        let url = repositoryPullLogURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static func repositoryPullLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Codex Keep", isDirectory: true)
            .appendingPathComponent("repository-pulls.log")
    }

    nonisolated private static func logCodexAppUpdateLine(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let url = codexAppUpdateLogURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static func codexAppUpdateLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Codex Keep", isDirectory: true)
            .appendingPathComponent("codex-app-updates.log")
    }

    nonisolated private static func appVersionDescription() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    nonisolated private static func lastBackupLogPhase() -> String? {
        guard let contents = try? String(contentsOf: backupRunLogURL(), encoding: .utf8) else {
            return nil
        }

        return contents
            .split(separator: "\n")
            .last
            .flatMap { line in
                let parts = line.split(separator: " ", maxSplits: 1)
                return parts.count == 2 ? String(parts[1]) : String(line)
            }
    }
}

private struct BackupAndPeerSyncResult: Sendable {
    var backupResult: BackupResult
    var peerSyncResult: PeerSyncApplyResult?
    var updatedSettings: BackupSettings
}

private struct PeerSyncReviewView: View {
    var items: [PeerSyncPlanItem]
    var incomingCount: Int
    var reviewCount: Int
    var localChangedCount: Int
    var warnings: [String]
    var onCancel: () -> Void
    var onSync: (Set<String>) -> Void

    @State private var selectedItemIDs: Set<String>

    init(
        items: [PeerSyncPlanItem],
        incomingCount: Int,
        reviewCount: Int,
        localChangedCount: Int,
        warnings: [String],
        onCancel: @escaping () -> Void,
        onSync: @escaping (Set<String>) -> Void
    ) {
        self.items = items
        self.incomingCount = incomingCount
        self.reviewCount = reviewCount
        self.localChangedCount = localChangedCount
        self.warnings = warnings
        self.onCancel = onCancel
        self.onSync = onSync
        self._selectedItemIDs = State(initialValue: Set(items.filter(\.isAutomatic).map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            peerItemList
            footer
        }
        .padding(24)
        .frame(minWidth: 680, maxWidth: 680, minHeight: 480, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sync Peer Changes")
                .font(.title2.weight(.semibold))

            Text("\(incomingCount) non-conflicting peer files are selected by default. \(reviewCount) conflicts or deletions need review.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if localChangedCount > 0 {
                Text("\(localChangedCount) files changed locally and will be left for the peer Mac to pull.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !warnings.isEmpty {
                Text(warnings.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var peerItemList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    peerItemRow(item)

                    if item.id != items.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxHeight: 320)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func peerItemRow(_ item: PeerSyncPlanItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(item.backupRelativePath) - \(statusText(for: item))")
                    .font(.caption)
                    .foregroundStyle(item.replacesLocalWhenReviewed ? .primary : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text("\(item.peerName), \(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Toggle("", isOn: binding(for: item))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!isSelectable(item))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("A sync safety snapshot is saved before local files are changed or deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Cancel", action: onCancel)

            Button("Sync Selected") {
                onSync(selectedItemIDs)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedItemIDs.isEmpty)
        }
    }

    private func binding(for item: PeerSyncPlanItem) -> Binding<Bool> {
        Binding(
            get: {
                selectedItemIDs.contains(item.id)
            },
            set: { isSelected in
                if isSelected {
                    selectedItemIDs.insert(item.id)
                } else {
                    selectedItemIDs.remove(item.id)
                }
            }
        )
    }

    private func isSelectable(_ item: PeerSyncPlanItem) -> Bool {
        switch item.status {
        case .incomingNew, .incomingChanged, .peerDeletedReviewRequired:
            true
        case .conflict:
            item.peerSHA256 != nil
        case .unchanged, .localChanged:
            false
        }
    }

    private func statusText(for item: PeerSyncPlanItem) -> String {
        switch item.status {
        case .incomingNew:
            "new from \(item.peerName)"
        case .incomingChanged:
            "changed on \(item.peerName)"
        case .conflict:
            item.replacesLocalWhenReviewed ? "replace local after review" : item.peerSHA256 == nil ? "delete conflict" : "save peer conflict copy"
        case .peerDeletedReviewRequired:
            "delete requested by \(item.peerName)"
        case .unchanged:
            "unchanged"
        case .localChanged:
            "local changed"
        }
    }
}

private struct TrustedMachinesView: View {
    var machineNames: [String]
    var backupFolderPath: String
    var currentMachineName: String
    var onSelectionChange: (Set<String>) -> Void
    var onOpenBackupFolder: () -> Void

    @State private var selectedMachineNames: Set<String>

    init(
        machineNames: [String],
        selectedMachineNames: Set<String>,
        backupFolderPath: String,
        currentMachineName: String,
        onSelectionChange: @escaping (Set<String>) -> Void,
        onOpenBackupFolder: @escaping () -> Void
    ) {
        self.machineNames = machineNames
        self.backupFolderPath = backupFolderPath
        self.currentMachineName = currentMachineName
        self.onSelectionChange = onSelectionChange
        self.onOpenBackupFolder = onOpenBackupFolder
        self._selectedMachineNames = State(initialValue: selectedMachineNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if machineNames.isEmpty {
                emptyState
            } else {
                machineList
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backup folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(backupFolderPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                Button("Open Folder", action: onOpenBackupFolder)
            }
        }
        .padding(24)
        .frame(minWidth: 520, maxWidth: 520, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trusted Machines")
                .font(.title2.weight(.semibold))

            Text("Choose which machine backups this Mac should review and sync from.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("This Mac: \(currentMachineName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No peer machine backups found")
                .font(.headline)
            Text("Run Codex Keep on another Mac using this same backup folder, then come back here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var machineList: some View {
        VStack(spacing: 0) {
            ForEach(machineNames, id: \.self) { machineName in
                machineRow(machineName)

                if machineName != machineNames.last {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func machineRow(_ machineName: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(machineName)
                    .font(.body.weight(.medium))
                Text("Review and sync from this backup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: binding(for: machineName))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func binding(for machineName: String) -> Binding<Bool> {
        Binding(
            get: {
                selectedMachineNames.contains(machineName)
            },
            set: { isSelected in
                if isSelected {
                    selectedMachineNames.insert(machineName)
                } else {
                    selectedMachineNames.remove(machineName)
                }

                onSelectionChange(selectedMachineNames)
            }
        )
    }
}

private struct ManageAutomationsView: View {
    var automations: [AutomationSummary]
    var pendingMoves: [PendingAutomationMoveSummary]
    var targetMachineNames: [String]
    var currentMachineName: String
    var backupFolderPath: String
    var onMove: (Set<String>, String) -> Void
    var onConfigureTrustedMachines: () -> Void
    var onInstallIncomingMoves: () -> Void
    var onOpenBackupFolder: () -> Void

    @State private var selectedAutomationIDs: Set<String> = []
    @State private var selectedTargetMachineName: String

    init(
        automations: [AutomationSummary],
        pendingMoves: [PendingAutomationMoveSummary],
        targetMachineNames: [String],
        currentMachineName: String,
        backupFolderPath: String,
        onMove: @escaping (Set<String>, String) -> Void,
        onConfigureTrustedMachines: @escaping () -> Void,
        onInstallIncomingMoves: @escaping () -> Void,
        onOpenBackupFolder: @escaping () -> Void
    ) {
        self.automations = automations
        self.pendingMoves = pendingMoves
        self.targetMachineNames = targetMachineNames
        self.currentMachineName = currentMachineName
        self.backupFolderPath = backupFolderPath
        self.onMove = onMove
        self.onConfigureTrustedMachines = onConfigureTrustedMachines
        self.onInstallIncomingMoves = onInstallIncomingMoves
        self.onOpenBackupFolder = onOpenBackupFolder
        self._selectedTargetMachineName = State(initialValue: targetMachineNames.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if !pendingMoves.isEmpty {
                incomingMovesSection
            }

            if automations.isEmpty {
                emptyAutomationsState
            } else {
                targetPicker
                automationList
            }

            Divider()

            footer
        }
        .padding(24)
        .frame(minWidth: 580, maxWidth: 580, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manage Automations")
                .font(.title2.weight(.semibold))

            Text("Move local automations to one trusted Mac so scheduled jobs only live in one place.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("This Mac: \(currentMachineName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var targetPicker: some View {
        HStack(spacing: 12) {
            Text("Move to")
                .font(.body.weight(.medium))

            Picker("Move to", selection: $selectedTargetMachineName) {
                if targetMachineNames.isEmpty {
                    Text("No trusted machines").tag("")
                } else {
                    ForEach(targetMachineNames, id: \.self) { machineName in
                        Text(machineName).tag(machineName)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 260)

            Spacer()

            if targetMachineNames.isEmpty {
                Button("Trusted Machines", action: onConfigureTrustedMachines)
            }
        }
    }

    private var emptyAutomationsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No local automations found")
                .font(.headline)
            Text("This Mac does not currently have automation folders in ~/.codex/automations.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var incomingMovesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Incoming Moves")
                        .font(.headline)
                    Text("\(pendingMoves.count) pending move packages are waiting for this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Install Incoming", action: onInstallIncomingMoves)
                    .buttonStyle(.borderedProminent)
            }

            VStack(spacing: 0) {
                ForEach(pendingMoves) { move in
                    incomingMoveRow(move)

                    if move.id != pendingMoves.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    private func incomingMoveRow(_ move: PendingAutomationMoveSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(move.sourceMachineName)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(move.automationIDs.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var automationList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(automations) { automation in
                    automationRow(automation)

                    if automation.id != automations.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxHeight: 300)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func automationRow(_ automation: AutomationSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(automation.id)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(automation.fileCount) files, \(formattedByteCount(automation.byteCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: binding(for: automation.id))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Backup folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(backupFolderPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("Open Folder", action: onOpenBackupFolder)

            Button("Move Selected") {
                onMove(selectedAutomationIDs, selectedTargetMachineName)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedAutomationIDs.isEmpty || selectedTargetMachineName.isEmpty)
        }
    }

    private func binding(for automationID: String) -> Binding<Bool> {
        Binding(
            get: {
                selectedAutomationIDs.contains(automationID)
            },
            set: { isSelected in
                if isSelected {
                    selectedAutomationIDs.insert(automationID)
                } else {
                    selectedAutomationIDs.remove(automationID)
                }
            }
        )
    }

    private func formattedByteCount(_ byteCount: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
