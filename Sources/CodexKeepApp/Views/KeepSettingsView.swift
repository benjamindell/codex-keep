import CodexKeepCore
import SwiftUI

struct KeepSettingsView: View {
    @ObservedObject var presentation: KeepPresentation
    let perform: (KeepAction) -> Void
    let setTrustedMachines: (Set<String>) -> Void
    let setMachineRemoved: (String, Bool) -> Void

    private var section: SettingsSection { presentation.section ?? .machines }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $presentation.section) {
                    Section("Codex Keep") {
                        ForEach(SettingsSection.allCases) { section in
                            Label(section.title, systemImage: section.symbol).tag(section)
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Keep").font(.system(size: 12, weight: .medium))
                    Text(presentation.version).font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.frame(width: 210).background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title).font(.system(size: 23, weight: .semibold))
                    Text(section.description).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(24)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !presentation.canChangeSettings {
                            Label("Settings can be changed when the current backup or restore finishes.", systemImage: "clock")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        switch section {
                        case .machines: machines
                        case .backups: backups
                        case .automations: automations
                        case .secondary: secondary
                        case .general: general
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 8) {
                    if presentation.isBusy { ProgressView().controlSize(.small) }
                    Text(presentation.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(presentation.status)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
        }
        .tint(.blue)
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private var machines: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("THIS GROUP") {
                ForEach(presentation.machines) { machine in
                    MachineCard(machine: machine, backupIntervalMinutes: presentation.settings.backupIntervalMinutes,
                                trust: machine.isCurrent ? nil : Binding(
                                    get: { presentation.settings.trustedMachineNames.contains(machine.name) },
                                    set: { trusted in
                                        var selection = presentation.settings.trustedMachineNames
                                        if trusted { selection.insert(machine.name) } else { selection.remove(machine.name) }
                                        setTrustedMachines(selection)
                                    }
                                ), remove: { setMachineRemoved(machine.name, true) },
                                canChangeSettings: presentation.canChangeSettings)
                }
                Text("Machines appear when they publish a backup to the same folder. Times show their last published backup, not a live connection. Roles appear after each Mac runs the updated app.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !presentation.settings.removedMachineNames.isEmpty {
                DisclosureGroup("Removed machines") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Removed on this Mac. Their backups are still available for restore.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(presentation.settings.removedMachineNames.sorted(), id: \.self) { name in
                            HStack {
                                Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Add Back") { setMachineRemoved(name, false) }
                                    .disabled(!presentation.canChangeSettings)
                            }
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 12))
            }
            settingsGroup("SYNC") {
                settingsToggle("Automatically sync trusted Macs",
                               detail: "Apply non-conflicting file creates and updates. Deletions and conflicts always need review.",
                               value: presentation.settings.automaticallySyncTrustedMachines, action: .autoSync)
                    .disabled(presentation.settings.trustedMachineNames.isEmpty)
                if presentation.settings.trustedMachineNames.isEmpty {
                    Text("Trust another Mac above to enable automatic sync.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                settingsToggle("Sync local development files",
                               detail: "Include selected repository .env and local settings files, .vscode settings, and AWS credentials. Repository files sync only to matching checkouts.",
                               value: presentation.settings.syncRepositoryDevFiles, action: .repositoryDevFiles)
                actionRow("Review peer changes", detail: "Choose incoming changes before applying them to this Mac.", button: "Review…", action: .reviewChanges)
                    .disabled(!presentation.canChangeSettings)
            }
        }
    }

    private var backups: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("BACKUP FOLDER") {
                Text(presentation.settings.destinationRootPath).font(.system(size: 12))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Folder") { perform(.openFolder) }
                    Button("Choose Folder…") { perform(.chooseFolder) }.disabled(!presentation.canChangeSettings)
                }
            }
            settingsGroup("BACKUP & RESTORE") {
                actionRow("Back up this Mac", detail: "Runs every \(presentation.settings.backupIntervalMinutes) minutes. Keeps the seven newest daily snapshots.",
                          button: presentation.isBackingUp ? "Saving…" : "Back Up Now", action: .backUp)
                    .disabled(!presentation.canChangeSettings)
                actionRow("Restore to this Mac", detail: "Review a backup and select what to restore. A safety snapshot is saved before replacing local files.",
                          button: "Review Backup…", action: .restore).disabled(!presentation.canChangeSettings)
            }
            settingsGroup("WHAT’S INCLUDED") {
                Text("Codex instructions, rules, skills, configuration, and automations, plus your Markdown-backed Codex folders and shared agent skills.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("Auth files, sessions, databases, caches, and logs are excluded. Codex configuration is backed up for restore; it stays local during trusted-machine sync.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var automations: some View {
        settingsGroup("SCHEDULED JOBS") {
            actionRow("Move automations", detail: "Choose individual jobs and their destination Mac. The source saves a safety snapshot, then removes the moved jobs.",
                      button: "Manage…", action: .manageAutomations).disabled(!presentation.canChangeSettings)
            Divider()
            Text("Incoming moves install before the next backup. You can also review and install them from Manage Automations.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("Automations are excluded from automatic peer sync so the same scheduled job does not run on multiple Macs.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var secondary: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("THIS MAC’S ROLE") {
                settingsToggle("Secondary Machine Mode", detail: "Use this for an always-on Mac. With this off, this Mac is shown as Primary.",
                               value: presentation.settings.secondaryMachineMode, action: .secondaryMode)
                Text("Roles describe each Mac’s setup. They do not appoint a sync leader or limit the group to one primary Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            settingsGroup("REPOSITORIES") {
                actionRow("Pull repositories", detail: "Secondary Macs update ~/Repositories every 30 minutes. Eligible generated artifacts are committed; other local edits, missing upstreams, and conflicts are skipped.",
                          button: presentation.isPullingRepositories ? "Pulling…" : "Pull Now", action: .pullRepositories)
                    .disabled(presentation.isPullingRepositories || presentation.isDeploying)
                Button("Open Repository Log") { perform(.repositoryLog) }
            }
            settingsGroup("CODEX APP") {
                actionRow("Keep Codex up to date", detail: "Secondary Macs check at 5 a.m. local time. Updates wait while Codex is working or a backup or repository pull is running.",
                          button: "Check Now", action: .updateCodex).disabled(presentation.isBusy)
                Button("Open Codex Update Log") { perform(.codexUpdateLog) }
            }
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("STARTUP & UPDATES") {
                settingsToggle("Launch at login", detail: "Keep backups running whenever you sign in to this Mac.",
                               value: presentation.launchAtLogin, action: .launchAtLogin)
                actionRow("Codex Keep \(presentation.version)", detail: "Automatic update checks are enabled. Check for the latest release now.",
                          button: "Check for Updates…", action: .checkForUpdates)
            }
            settingsGroup("DIAGNOSTICS") {
                actionRow("Backup and sync log", detail: "See the phases and results of the latest backup run.", button: "Open Log", action: .backupLog)
                actionRow("Repository pull log", detail: "See which repositories were updated or skipped.", button: "Open Log", action: .repositoryLog)
                actionRow("Codex update log", detail: "See update checks and reasons an update was deferred.", button: "Open Log", action: .codexUpdateLog)
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: title)
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).panelCard()
        }
    }

    private func settingsToggle(_ title: String, detail: String, value: Bool, action: KeepAction) -> some View {
        HStack(spacing: 20) {
            rowText(title, detail: detail)
            Spacer(minLength: 0)
            Toggle(title, isOn: Binding(get: { value }, set: { _ in perform(action) }))
                .toggleStyle(.switch).labelsHidden().accessibilityLabel(title)
        }.disabled(!presentation.canChangeSettings)
    }

    private func actionRow(_ title: String, detail: String, button: String, action: KeepAction) -> some View {
        HStack(alignment: .center, spacing: 20) {
            rowText(title, detail: detail)
            Spacer(minLength: 0)
            Button(button) { perform(action) }.fixedSize()
        }
    }

    private func rowText(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
