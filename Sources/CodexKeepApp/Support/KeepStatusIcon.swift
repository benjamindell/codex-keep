import AppKit

/// A single template image keeps the menu bar item stable through every activity state.
@MainActor enum KeepStatusIcon {
    static func makeImage() -> NSImage {
        let logo = Bundle.module.url(forResource: "ChatGPTLogo", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
        let drive = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        let image = NSImage(size: NSSize(width: 24, height: 20), flipped: false) { _ in
            drive?.draw(in: NSRect(x: 3, y: 4, width: 21, height: 16))
            // Use the Codex knot in the cloud badge's lower-left position.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 11, height: 11), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            logo?.draw(in: NSRect(x: -1.5, y: -1.5, width: 14, height: 14))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Keep"
        return image
    }
}
