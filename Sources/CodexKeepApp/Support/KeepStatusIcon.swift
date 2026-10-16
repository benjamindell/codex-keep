import AppKit

/// A single template image keeps the menu bar item stable through every activity state.
@MainActor enum KeepStatusIcon {
    static func makeImage() -> NSImage {
        let logo = Bundle.module.url(forResource: "ChatGPTLogo", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
        let drive = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        let image = NSImage(size: NSSize(width: 24, height: 20), flipped: false) { _ in
            logo?.draw(in: NSRect(x: -2, y: -2, width: 25, height: 25))
            // Clear a small badge backing so the drive stays legible over the knot.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 14, y: 10, width: 10, height: 9), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            drive?.draw(in: NSRect(x: 15, y: 11, width: 9, height: 7))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Keep"
        return image
    }
}
