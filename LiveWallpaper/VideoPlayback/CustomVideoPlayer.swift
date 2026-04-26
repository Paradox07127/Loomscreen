import SwiftUI
import AppKit
import AVKit

/// 自管 NSView + AVPlayerLayer 的 SwiftUI wrapper。
///
/// 之前用 `AVPlayerView`：
/// - 它的 `intrinsicContentSize` = 视频原生分辨率，导致 SwiftUI 在含
///   `aspectRatio(16/9)` 的父视图里仍按视频自身比例 layout，切换不同
///   分辨率的视频时 preview 容器尺寸抖动。
/// - 内部 `AVPlayerLayer` 默认黑色背景，在父视图 `.clipShape` 外侧仍
///   渲染矩形黑边。
///
/// 直接管理 `AVPlayerLayer` 可同时去掉这两个副作用：
/// - `intrinsicContentSize = .zero` 让 SwiftUI 完全按 frame 布局；
/// - host view 与 layer 双层 `backgroundColor = clear`，圆角裁剪外
///   不再漏出黑色矩形。
struct CustomVideoPlayer: NSViewRepresentable {
    var player: AVPlayer
    var fitMode: VideoFitMode = .aspectFill

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let host = PlayerLayerHostView()
        host.attach(player: player, gravity: fitMode.avLayerVideoGravity)
        return host
    }

    func updateNSView(_ host: PlayerLayerHostView, context: Context) {
        if host.player !== player {
            host.attach(player: player, gravity: fitMode.avLayerVideoGravity)
        } else {
            host.gravity = fitMode.avLayerVideoGravity
        }

        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
    }
}

/// 承载 `AVPlayerLayer` 的 NSView。Layer 的尺寸跟随 view 的 bounds，
/// 始终透明背景；intrinsic size = .zero 让父布局（SwiftUI）独享尺寸决策。
final class PlayerLayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? { playerLayer.player }

    var gravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        // host view 透明
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        // player layer 同样透明，避免 letterbox 区域出现黑色矩形
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    /// 拒绝把视频原生分辨率作为 intrinsic size，让 SwiftUI 完全控制 layout。
    override var intrinsicContentSize: NSSize { .zero }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func attach(player: AVPlayer, gravity: AVLayerVideoGravity) {
        playerLayer.player = player
        playerLayer.videoGravity = gravity
    }
}
