import AppKit
import CodexKeepCore
import ServiceManagement
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settingsStore = SettingsStore()
    private let backupService = BackupService()
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
