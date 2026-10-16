import AppKit

/// A single template image keeps the menu bar item stable through every activity state.
@MainActor enum KeepStatusIcon {
    static func makeImage() -> NSImage {
        let logo = Bundle.module.url(forResource: "ChatGPTLogo", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
        let drive = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        let image = NSImage(size: NSSize(width: 28, height: 20), flipped: false) { _ in
            // Match Codex LB's 17-point SVG canvas, including its optical padding.
            logo?.draw(in: NSRect(x: 0, y: 1.5, width: 17, height: 17))
            // Clear a small badge backing so the drive stays legible over the knot.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 13.5, y: 8, width: 14.5, height: 12), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            drive?.draw(in: NSRect(x: 14.5, y: 9, width: 13.5, height: 10.5))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Keep"
        return image
    }
}
