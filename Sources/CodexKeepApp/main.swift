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
    private var lastResult: BackupResult?
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
        menu.addItem(actionItem(title: "Open Backup Folder", action: #selector(openBackupFolder), keyEquivalent: "o"))
        menu.addItem(actionItem(title: "Deploy Backup to This Mac...", action: #selector(deployBackupToThisMac), keyEquivalent: "d"))
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

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func statusTitle() -> String {
        if isBackingUp {
            return "Backing up Codex files..."
        }

        if let result = lastResult {
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
                try BackupService().runBackup(settings: settings)
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
                case let .success(backupResult):
                    self.lastResult = backupResult
                    self.lastError = nil
                case let .failure(error):
                    self.lastError = error
                    self.lastResult = nil
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
