import CodexKeepCore
import SwiftUI

struct MachineCard: View {
    let machine: MachineOverview
    var activity: String? = nil
    var backupIntervalMinutes = 30
    var trust: Binding<Bool>? = nil
    var remove: (() -> Void)? = nil
    var canChangeSettings = true

    private var role: String {
        switch machine.secondaryMachineMode {
        case true: "Secondary"
        case false: "Primary"
        case nil: "Role unavailable"
        }
    }

    private var detail: String {
        role + (machine.isCurrent ? " · This Mac" : machine.isTrusted ? " · Trusted" : " · Not trusted")
    }

    private var statusColor: Color {
        guard let date = machine.lastBackupAt else { return .secondary }
        return Date().timeIntervalSince(date) > Double(max(backupIntervalMinutes, 5) * 120) ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: machine.secondaryMachineMode == true ? "server.rack" : "desktopcomputer")
                    .font(.system(size: 17))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(machine.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .truncationMode(.middle).help(machine.name)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if activity != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: machine.isCurrent ? "checkmark.circle" : machine.isTrusted ? "link" : "minus.circle")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(activity == nil ? statusColor : .blue).frame(width: 5, height: 5)
                if let activity {
                    Text(activity).lineLimit(1).truncationMode(.middle)
                } else if let date = machine.lastBackupAt {
                    Text("Last backup")
                    Text(date, style: .relative)
                    Text("ago")
                } else {
                    Text(machine.isCurrent ? "First backup pending" : "Backup not available locally")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .help(machine.lastBackupAt.map { "Last published backup: \($0.formatted(date: .abbreviated, time: .standard))" }
                  ?? "Waiting for a locally readable backup manifest. Role information appears after this Mac runs the updated app.")
            if !machine.isCurrent, let trust {
                Divider()
                HStack {
                    Toggle("Trust this Mac", isOn: trust)
                        .toggleStyle(.switch).font(.system(size: 12))
                    Spacer()
                    if let remove {
                        Button("Remove", action: remove)
                            .help("Remove this Mac from the group on this Mac. Its backups are kept.")
                    }
                }.disabled(!canChangeSettings)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }
}
