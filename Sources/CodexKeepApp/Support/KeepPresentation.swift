import CodexKeepCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case machines, backups, automations, secondary, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .machines: "Machines & Sync"
        case .backups: "Backups & Restore"
        case .automations: "Automations"
        case .secondary: "Secondary Mac"
        case .general: "General"
        }
    }
    var symbol: String {
        switch self {
        case .machines: "desktopcomputer"
        case .backups: "externaldrive.badge.icloud"
        case .automations: "clock.arrow.2.circlepath"
        case .secondary: "server.rack"
        case .general: "gearshape"
        }
    }
    var description: String {
        switch self {
        case .machines: "Choose the Macs you trust and how their changes reach this Mac."
        case .backups: "Keep a copy of your Codex setup and restore it when you need it."
        case .automations: "Move scheduled jobs to the Mac where you want them to run."
        case .secondary: "Keep an always-on Mac ready for remote Codex work."
        case .general: "Manage startup, app updates, and diagnostic logs."
        }
    }
}

enum KeepAction {
    case backUp, openFolder, chooseFolder, restore, reviewChanges, manageAutomations
    case autoSync, repositoryDevFiles, secondaryMode, pullRepositories, updateCodex
    case launchAtLogin, checkForUpdates, backupLog, repositoryLog, codexUpdateLog, quit
}

@MainActor final class KeepPresentation: ObservableObject {
    @Published var settings = BackupSettings(destinationRootPath: "", enabledItemIDs: [])
    @Published var machines: [MachineOverview] = []
    @Published var section: SettingsSection? = .machines
    @Published var status = "Codex Keep is ready"
    @Published var activity = "Ready"
    @Published var error: String?
    @Published var isBackingUp = false
    @Published var isDeploying = false
    @Published var isPullingRepositories = false
    @Published var launchAtLogin = false
    @Published var version = ""
    @Published var availableCardHeight: CGFloat = 500

    var canChangeSettings: Bool { !isBackingUp && !isDeploying }
    var isBusy: Bool { isBackingUp || isDeploying || isPullingRepositories }
}
