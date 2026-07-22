import AppKit
import WebKit

/// Wallpaper web view that accepts first-mouse events and removes irrelevant browser menu actions.
/// It remains in this package to isolate AppKit importer overhead from the app target's expression diagnostics.
public final class HTMLWebView: WKWebView {
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let blockedMenuTitles: Set<String> = [
        "Download Image",
        "Download Linked File",
        "Download Video",
        "Open Image in New Window",
        "Open Video in New Window",
        "Open Frame in New Window",
        "Open Link in New Window",
        "Share",
        "Enter Full Screen",
        "Enter Enhanced Full Screen"
    ]

    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items where HTMLWebView.blockedMenuTitles.contains(item.title) {
            menu.removeItem(item)
        }
    }
}
