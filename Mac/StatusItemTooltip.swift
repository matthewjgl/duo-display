import AppKit

/// Hover text for the menu bar icon. SwiftUI's `MenuBarExtra` owns its
/// `NSStatusItem` and exposes no handle to it, so this finds the status bar
/// button (a public `NSButton` subclass, `NSStatusBarButton`) among the app's
/// windows and sets its `toolTip`. If the button cannot be found (a future
/// macOS changes the hierarchy, or the icon is hidden) this does nothing: the
/// click-to-open readout in the menu is the primary display, the tooltip is
/// a bonus.
@MainActor
enum StatusItemTooltip {
    static func set(_ text: String?) {
        for window in NSApp.windows {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            if let button = findStatusButton(in: root) {
                if button.toolTip != text { button.toolTip = text }
            }
        }
    }

    private static func findStatusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findStatusButton(in: sub) { return found }
        }
        return nil
    }
}
