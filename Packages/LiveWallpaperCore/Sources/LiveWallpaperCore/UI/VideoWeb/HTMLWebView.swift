import AppKit
import WebKit

/// `WKWebView` 子类：开启 first-mouse 接收（Plash 模式），关闭 Force-Touch 链接预览，
/// 过滤右键菜单中无意义项（下载图片 / 分享 / 在新窗口打开等）。
///
/// Lives in this package (not the app target) deliberately: the first
/// NSMenu-member lookup in a compilation pays ~450ms of lazy importer work,
/// which kept tripping the app target's `-warn-long-*` 300ms diagnostics on
/// whatever expression touched it first. Package targets don't inherit those
/// flags, and the cost itself is unavoidable wherever this class compiles.
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
