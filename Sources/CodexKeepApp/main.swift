import AppKit
import CodexKeepCore
import ServiceManagement
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settingsStore = SettingsStore()
    private let backupService = BackupService()
    private let deployService = DeployService()
    private let peerSyncService = PeerSyncService()
    private let automationMoveService = AutomationMoveService()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var timer: Timer?
    private var animationTimer: Timer?
    private var trustedMachinesWindowController: NSWindowController?
    private var manageAutomationsWindowController: NSWindowController?
    private var lastResult: BackupResult?
    private var lastPeerSyncResult: PeerSyncApplyResult?
    private var lastError: Error?
    private weak var statusMenuItem: NSMenuItem?
    private var isBackingUp = false
    private var animationFrame = 0
    private let animationFrames = ["|", "/", "-", "\\"]
    private let minimumSyncIndicatorDuration: TimeInterval = 1.25

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        rebuildMenu()
        runBackup()
        scheduleTimer()
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
        menu.addItem(actionItem(title: "Deploy Backup to This Mac...", action: #selector(deployBackupToThisMac), keyEquivalent: "d"))
        menu.addItem(actionItem(title: "Trusted Machines...", action: #selector(configureTrustedMachines), keyEquivalent: "t"))
        menu.addItem(actionItem(title: "Manage Automations...", action: #selector(manageAutomations), keyEquivalent: "m"))
        menu.addItem(autoSyncItem())
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

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func statusTitle() -> String {
        if isBackingUp {
            return "Backing up Codex files..."
        }

        if let result = lastResult {
            if let lastPeerSyncResult, lastPeerSyncResult.appliedItemCount > 0 {
                return "Last synced \(lastPeerSyncResult.appliedItemCount) peer files \(relativeSyncTime(since: result.manifest.createdAt))"
            }

            return "Last synced \(relativeSyncTime(since: result.manifest.createdAt))"
        }

        if let lastError {
            return "Backup failed: \(lastError.localizedDescription)"
        }

        return "Codex Keep is ready"
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
            let targetMachineNames = settingsStore.settings.trustedMachineNames.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            let view = ManageAutomationsView(
                automations: automations,
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
            window.setContentSize(NSSize(width: 660, height: automations.isEmpty ? 320 : min(620, 300 + automations.count * 54)))
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

    @objc private func checkForUpdates() {
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func runBackup() {
        guard !isBackingUp else {
            return
        }

        isBackingUp = true
        lastError = nil
        startSyncAnimation()
        rebuildMenu()

        let settings = settingsStore.settings
        let startedAt = Date()
        let minimumSyncIndicatorDuration = minimumSyncIndicatorDuration

        Task.detached {
            let result = Result {
                try Self.runBackupAndPeerSync(settings: settings)
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            let remaining = minimumSyncIndicatorDuration - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }

            await MainActor.run {
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
        updateStatusItemForSync()
    }

    private func stopSyncAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
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

        let alert = NSAlert()
        alert.messageText = visibleItems.isEmpty ? "No peer changes to sync" : "Sync peer changes?"
        alert.informativeText = peerSyncPlanSummary(plans)
        alert.alertStyle = plans.contains { $0.reviewItemCount > 0 } ? .warning : .informational

        if visibleItems.isEmpty {
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }

        if selectableItems.isEmpty {
            alert.messageText = "Peer changes need manual review"
            alert.addButton(withTitle: "OK")
            alert.accessoryView = peerSyncChecklistView(for: plans).view
            alert.runModal()
            return nil
        }

        alert.addButton(withTitle: "Sync Selected")
        alert.addButton(withTitle: "Cancel")

        let checklist = peerSyncChecklistView(for: plans)
        alert.accessoryView = checklist.view

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let selectedIDs = Set(checklist.checkboxes.compactMap { id, checkbox in
            checkbox.state == .on ? id : nil
        })

        if selectedIDs.isEmpty {
            presentError(
                PeerSyncServiceError.noSelectedItems,
                messageText: "Codex Keep could not sync peer changes."
            )
            return nil
        }

        return selectedIDs
    }

    private func peerSyncChecklistView(for plans: [PeerSyncPlan]) -> (view: NSView, checkboxes: [(String, NSButton)]) {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        var checkboxes: [(String, NSButton)] = []

        for plan in plans {
            for item in plan.items {
                switch item.status {
                case .incomingNew, .incomingChanged, .conflict, .peerDeletedReviewRequired:
                    let checkbox = NSButton(checkboxWithTitle: peerSyncCheckboxTitle(for: item), target: nil, action: nil)
                    checkbox.state = item.isAutomatic ? .on : .off
                    checkbox.isEnabled = isSelectablePeerSyncItem(item)
                    checkbox.toolTip = item.targetPath
                    checkbox.lineBreakMode = .byTruncatingMiddle
                    checkbox.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true
                    checkboxes.append((item.id, checkbox))
                    stackView.addArrangedSubview(checkbox)
                case .unchanged, .localChanged:
                    continue
                }
            }
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: 640).isActive = true
        let checklistHeight = CGFloat(min(380, max(120, checkboxes.count * 26)))
        scrollView.heightAnchor.constraint(equalToConstant: checklistHeight).isActive = true

        return (scrollView, checkboxes)
    }

    private func peerSyncCheckboxTitle(for item: PeerSyncPlanItem) -> String {
        let status: String
        switch item.status {
        case .incomingNew:
            status = "new from \(item.peerName)"
        case .incomingChanged:
            status = "changed on \(item.peerName)"
        case .conflict:
            status = item.peerSHA256 == nil ? "delete conflict" : "conflict copy"
        case .peerDeletedReviewRequired:
            status = "delete requested by \(item.peerName)"
        case .unchanged:
            status = "unchanged"
        case .localChanged:
            status = "local changed"
        }

        return "\(item.displayName) (\(status))"
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
        alert.informativeText = "\(result.appliedItemCount) files updated, \(result.conflictCopyCount) conflict copies saved, \(result.deletedItemCount) files deleted, \(result.skippedItemCount) stale files skipped. Safety snapshot: \(result.safetySnapshotURL.path)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Safety Snapshot")

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(result.safetySnapshotURL)
        }
    }

    private func presentAutomationMoveSuccess(_ result: AutomationMoveResult, targetMachineName: String) {
        let alert = NSAlert()
        alert.messageText = "Automations moved"
        alert.informativeText = "\(result.movedCount) automations were moved to \(targetMachineName). They will be installed there the next time Codex Keep runs on that Mac. Safety snapshot: \(result.safetySnapshotURL.path)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Safety Snapshot")

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(result.safetySnapshotURL)
        }
    }

    nonisolated private static func runBackupAndPeerSync(settings: BackupSettings) throws -> BackupAndPeerSyncResult {
        let backupService = BackupService()
        let peerSyncService = PeerSyncService()
        let automationMoveService = AutomationMoveService()
        var workingSettings = settings
        _ = try automationMoveService.consumePendingMoves(settings: workingSettings)
        var backupResult = try backupService.runBackup(settings: workingSettings)

        let settingsAfterLocalState = peerSyncService.settingsByRecordingLocalState(
            workingSettings,
            localManifest: backupResult.manifest
        )
        if settingsAfterLocalState != workingSettings {
            workingSettings = settingsAfterLocalState
            backupResult = try backupService.runBackup(settings: workingSettings)
        }

        var peerSyncResult: PeerSyncApplyResult?
        if workingSettings.automaticallySyncTrustedMachines,
           !workingSettings.trustedMachineNames.isEmpty {
            let plans = try peerSyncService.makePlans(
                settings: workingSettings,
                localManifest: backupResult.manifest
            )
            workingSettings = peerSyncService.settingsByRecordingUnchangedPeerFiles(
                workingSettings,
                plans: plans
            )

            let automaticItemIDs = Set(plans.flatMap(\.automaticItemIDs))
            if !automaticItemIDs.isEmpty {
                let applied = try peerSyncService.apply(
                    plans: plans,
                    selectedItemIDs: automaticItemIDs,
                    settings: workingSettings
                )
                workingSettings = applied.updatedSettings
                peerSyncResult = applied
                backupResult = try backupService.runBackup(settings: workingSettings)
            } else if workingSettings != settingsAfterLocalState {
                backupResult = try backupService.runBackup(settings: workingSettings)
            }
        }

        return BackupAndPeerSyncResult(
            backupResult: backupResult,
            peerSyncResult: peerSyncResult,
            updatedSettings: workingSettings
        )
    }
}

private struct BackupAndPeerSyncResult: Sendable {
    var backupResult: BackupResult
    var peerSyncResult: PeerSyncApplyResult?
    var updatedSettings: BackupSettings
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
    var targetMachineNames: [String]
    var currentMachineName: String
    var backupFolderPath: String
    var onMove: (Set<String>, String) -> Void
    var onConfigureTrustedMachines: () -> Void
    var onOpenBackupFolder: () -> Void

    @State private var selectedAutomationIDs: Set<String> = []
    @State private var selectedTargetMachineName: String

    init(
        automations: [AutomationSummary],
        targetMachineNames: [String],
        currentMachineName: String,
        backupFolderPath: String,
        onMove: @escaping (Set<String>, String) -> Void,
        onConfigureTrustedMachines: @escaping () -> Void,
        onOpenBackupFolder: @escaping () -> Void
    ) {
        self.automations = automations
        self.targetMachineNames = targetMachineNames
        self.currentMachineName = currentMachineName
        self.backupFolderPath = backupFolderPath
        self.onMove = onMove
        self.onConfigureTrustedMachines = onConfigureTrustedMachines
        self.onOpenBackupFolder = onOpenBackupFolder
        self._selectedTargetMachineName = State(initialValue: targetMachineNames.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

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
