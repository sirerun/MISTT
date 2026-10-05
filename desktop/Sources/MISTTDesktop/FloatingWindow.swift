import AppKit
import SwiftUI

/// Configures only the window hosting this view, including the fixture host.
struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAttachment { WindowAttachment() }
    func updateNSView(_ nsView: WindowAttachment, context: Context) {}

    final class WindowAttachment: NSView {
        private weak var configuredWindow: NSWindow?
        private var legacyPan: NSPanGestureRecognizer?
        private var dragOrigin: NSPoint?
        private var mouseOrigin: NSPoint?
        @objc private func dragWindow(_ pan: NSPanGestureRecognizer) {
            guard let window = configuredWindow else { return }
            switch pan.state {
            case .began:
                dragOrigin = window.frame.origin
                mouseOrigin = NSEvent.mouseLocation
            case .changed:
                guard let dragOrigin, let mouseOrigin else { return }
                let mouse = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(x: dragOrigin.x + mouse.x - mouseOrigin.x,
                                              y: dragOrigin.y + mouse.y - mouseOrigin.y))
            case .ended, .cancelled, .failed:
                dragOrigin = nil
                mouseOrigin = nil
            default: break
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            if let legacyPan { legacyPan.view?.removeGestureRecognizer(legacyPan) }
            configuredWindow = window
            if #available(macOS 15.0, *) {} else {
                let pan = NSPanGestureRecognizer(target: self, action: #selector(dragWindow(_:)))
                pan.buttonMask = 1
                pan.delaysPrimaryMouseButtonEvents = true
                window.contentView?.addGestureRecognizer(pan)
                legacyPan = pan
            }
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
            window.setFrameAutosaveName("")
            DispatchQueue.main.async { [weak window] in
                guard let window, let screen = window.screen ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - window.frame.width - 24), y: visible.minY + 24))
            }
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
                .simultaneousGesture(WindowDragGesture())
                .allowsWindowActivationEvents()
        } else {
            content
        }
    }
}
