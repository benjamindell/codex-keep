import AppKit
import SwiftUI

@MainActor final class KeepWindowController {
    private let statusItem: NSStatusItem
    private let presentation: KeepPresentation
    private let panel = KeepMenuPanel()
    private let perform: (KeepAction) -> Void
    private let refresh: () -> Void
    private let setTrustedMachines: (Set<String>) -> Void
    private var settingsWindow: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchor: NSRect?
    private var screenFrame: NSRect?
    private var panelSize = NSSize(width: 384, height: 220)

    var hasVisibleWindow: Bool { panel.isVisible || settingsWindow?.isVisible == true }

    init(statusItem: NSStatusItem, presentation: KeepPresentation, perform: @escaping (KeepAction) -> Void,
         refresh: @escaping () -> Void, setTrustedMachines: @escaping (Set<String>) -> Void) {
        self.statusItem = statusItem
        self.presentation = presentation
        self.perform = perform
        self.refresh = refresh
        self.setTrustedMachines = setTrustedMachines
        let content = MenuPanel(presentation: presentation,
                                openSettings: { [weak self] in self?.showSettings(.machines) },
                                perform: { [weak self] action in self?.perform(action) })
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                Task { @MainActor in self?.resize(to: size) }
            }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.layer?.cornerRadius = 16
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.setContentSize(panelSize)
    }

    func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        presentation.availableCardHeight = max(80, min(500, (screenFrame?.height ?? 700) - 150))
        refresh()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        startDismissalMonitors()
    }

    func hidePanel() {
        panel.orderOut(nil)
        anchor = nil
        screenFrame = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func showSettings(_ section: SettingsSection) {
        hidePanel()
        presentation.section = section
        refresh()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Codex Keep Settings"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: GeometryReader { [presentation, perform, setTrustedMachines] geometry in
                KeepSettingsView(presentation: presentation, perform: perform, setTrustedMachines: setTrustedMachines)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            })
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.contentMinSize = NSSize(width: 760, height: 520)
            window.setFrameAutosaveName("CodexKeepSettings")
            window.setContentSize(NSSize(width: 900, height: 650))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, panelSize != size else { return }
        panelSize = size
        positionPanel()
        panel.invalidateShadow()
    }

    private func positionPanel() {
        guard let anchor, let screenFrame else {
            panel.setContentSize(panelSize)
            return
        }
        let x = min(max(anchor.midX - panelSize.width / 2, screenFrame.minX + 8), screenFrame.maxX - panelSize.width - 8)
        let y = max(screenFrame.minY + 8, anchor.minY - panelSize.height - 4)
        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: panel.isVisible)
    }

    private func startDismissalMonitors() {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events.union(.keyDown)) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53, self.panel.isVisible {
                        self.hidePanel()
                        return true
                    }
                } else if event.window !== self.panel, event.window !== self.statusItem.button?.window,
                          event.window?.level != .popUpMenu {
                    self.hidePanel()
                }
                return false
            }
            return consume ? nil : event
        }
    }
}

private final class KeepMenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Codex Keep"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
