import AppKit
import SwiftUI

/// Configures only the window hosting this view, including the fixture host.
struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAttachment { WindowAttachment() }
    func updateNSView(_ nsView: WindowAttachment, context: Context) {}

    final class WindowAttachment: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Keep the titled-window capability for keyboard focus, but hide chrome.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .floating
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.isMovableByWindowBackground = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        }
    }
}

struct FloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
    }
}
