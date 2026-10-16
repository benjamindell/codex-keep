import SwiftUI

struct MenuPanel: View {
    @ObservedObject var presentation: KeepPresentation
    let openSettings: () -> Void
    let perform: (KeepAction) -> Void
    @State private var contentHeight: CGFloat = 100

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: KeepStatusIcon.makeImage())
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 24, height: 20)
                    .foregroundStyle(.blue).frame(width: 32, height: 32)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                Text("Codex Keep").font(.system(size: 16, weight: .semibold))
                Spacer()
                Circle().fill(presentation.error != nil ? .orange : presentation.isBusy ? .blue : .green)
                    .frame(width: 5, height: 5)
                Text(presentation.activity).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }.frame(height: 34).help(presentation.status)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(presentation.machines) { machine in
                        Button(action: openSettings) {
                            MachineCard(machine: machine,
                                        activity: machine.isCurrent && presentation.isBusy ? presentation.status : nil,
                                        backupIntervalMinutes: presentation.settings.backupIntervalMinutes)
                        }.buttonStyle(.plain).help("Manage machines and sync")
                    }
                    if let error = presentation.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Needs attention", systemImage: "exclamationmark.circle")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
                            Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(3).help(error)
                        }.frame(maxWidth: .infinity, alignment: .leading).panelCard()
                    }
                }.frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, presentation.availableCardHeight))

            HStack(spacing: 4) {
                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape").labelStyle(CompactLabelStyle())
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 32)
                }.buttonStyle(HoverButtonStyle(isCard: true)).keyboardShortcut(",", modifiers: .command)
                Button { perform(.openFolder) } label: {
                    Label("Backups", systemImage: "folder").labelStyle(CompactLabelStyle())
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 32)
                }.buttonStyle(HoverButtonStyle(isCard: true)).help("Open backup folder")
                Spacer(minLength: 0)
                QuietIconButton(symbol: "arrow.clockwise", title: "Back up and sync now", isLoading: presentation.isBackingUp) {
                    perform(.backUp)
                }.disabled(presentation.isDeploying).keyboardShortcut("b", modifiers: .command)
                Divider().frame(height: 14).padding(.horizontal, 4)
                QuietIconButton(symbol: "power", title: "Quit Codex Keep", hoverColor: .red) { perform(.quit) }
                    .keyboardShortcut("q", modifiers: .command)
            }.frame(height: 32)
        }
        .padding(16).frame(width: 384)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .tint(.blue)
    }
}
