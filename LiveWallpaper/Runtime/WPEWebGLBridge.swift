#if !LITE_BUILD
import Foundation
@preconcurrency import WebKit

/// Swift ↔ JS message bridge for the WebGL2 WPE runtime.
///
/// Inbound (JS → Swift) lands as `WPEWebGLIncomingMessage` via
/// `WKScriptMessageHandler`. Outbound (Swift → JS) is sent via
/// `evaluateJavaScript("window.__wpeHost.<method>(payload)")`. Payloads
/// are encoded by `JSONEncoder` so the JS side gets a plain object via
/// `JSON.parse`.
///
/// The bridge is MainActor-isolated because WebKit invokes the message
/// handler on the main thread (documented) and the renderer owns it from
/// MainActor.
@MainActor
final class WPEWebGLBridge: NSObject {
    static let messageHandlerName = "wpe"
    static let scriptObjectName = "__wpeHost"

    weak var webView: WKWebView?

    var onReady: ((String?) -> Void)?
    var onSceneLoaded: ((String?) -> Void)?
    var onLoadFailed: ((WPEWebGLBridgeError) -> Void)?
    var onError: ((WPEWebGLBridgeError) -> Void)?
    var onDiagnostic: ((WPEWebGLDiagnostic) -> Void)?
    var onFrame: ((WPEWebGLFrameInfo) -> Void)?
    var onReadback: ((WPEWebGLReadback) -> Void)?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private let decoder = JSONDecoder()

    func loadScene(_ envelope: WPEPipelineEnvelope) {
        dispatch(method: "loadScene", payload: envelope)
    }

    func push(_ state: WPERuntimeStatePayload) {
        dispatch(method: "pushRuntimeState", payload: state)
    }

    func unloadCurrentScene() {
        invoke(method: "unloadCurrentScene", argumentsJSON: nil)
    }

    private func dispatch<T: Encodable>(method: String, payload: T) {
        do {
            let data = try encoder.encode(payload)
            guard let json = String(data: data, encoding: .utf8) else {
                Logger.warning("WPEWebGLBridge: payload not UTF-8 for \(method)", category: .screenManager)
                return
            }
            invoke(method: method, argumentsJSON: json)
        } catch {
            Logger.warning("WPEWebGLBridge: failed to encode \(method) — \(error.localizedDescription)", category: .screenManager)
        }
    }

    private func invoke(method: String, argumentsJSON: String?) {
        guard let webView else { return }
        let script: String
        if let argumentsJSON {
            script = "if (window.\(Self.scriptObjectName) && typeof window.\(Self.scriptObjectName).\(method) === 'function') { window.\(Self.scriptObjectName).\(method)(\(argumentsJSON)); }"
        } else {
            script = "if (window.\(Self.scriptObjectName) && typeof window.\(Self.scriptObjectName).\(method) === 'function') { window.\(Self.scriptObjectName).\(method)(); }"
        }
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                Logger.warning("WPEWebGLBridge: evaluateJavaScript(\(method)) failed — \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    fileprivate func handle(rawData data: Data) {
        let message: WPEWebGLIncomingMessage
        do {
            message = try decoder.decode(WPEWebGLIncomingMessage.self, from: data)
        } catch {
            Logger.warning("WPEWebGLBridge: malformed message — \(error.localizedDescription)", category: .screenManager)
            return
        }

        switch message.event {
        case .ready:
            onReady?(message.sceneID)
        case .sceneLoaded:
            onSceneLoaded?(message.sceneID)
        case .loadFailed:
            onLoadFailed?(WPEWebGLBridgeError(
                stage: message.stage ?? "load",
                passID: message.passID,
                message: message.message ?? ""
            ))
        case .error:
            onError?(WPEWebGLBridgeError(
                stage: message.stage ?? "unknown",
                passID: message.passID,
                message: message.message ?? ""
            ))
        case .diagnostic:
            onDiagnostic?(WPEWebGLDiagnostic(
                kind: message.kind ?? "info",
                message: message.message ?? ""
            ))
        case .frame:
            onFrame?(WPEWebGLFrameInfo(
                frameIndex: message.frameIndex ?? 0,
                elapsedMs: message.elapsedMs ?? 0
            ))
        case .readback:
            guard let width = message.width,
                  let height = message.height,
                  let base64 = message.dataBase64,
                  let raw = Data(base64Encoded: base64) else { return }
            onReadback?(WPEWebGLReadback(width: width, height: height, data: raw))
        }
    }

    /// Adapter that keeps the heavy MainActor-isolated bridge separate from the
    /// `NSObject`-conforming receiver WebKit expects. WebKit's API takes a
    /// `WKScriptMessageHandler` reference and holds it strongly via the user
    /// content controller, so a weak reference back to the bridge prevents a
    /// retain cycle through `WKWebViewConfiguration`.
    func receiverAdapter() -> WPEWebGLBridgeReceiver {
        WPEWebGLBridgeReceiver(bridge: self)
    }
}

struct WPEWebGLBridgeError: Sendable {
    let stage: String
    let passID: String?
    let message: String
}

struct WPEWebGLDiagnostic: Sendable {
    let kind: String
    let message: String
}

struct WPEWebGLFrameInfo: Sendable {
    let frameIndex: Int
    let elapsedMs: Double
}

struct WPEWebGLReadback: Sendable {
    let width: Int
    let height: Int
    let data: Data
}

/// `WKScriptMessageHandler`-conforming forwarder.
final class WPEWebGLBridgeReceiver: NSObject, WKScriptMessageHandler {
    private weak var bridge: WPEWebGLBridge?

    init(bridge: WPEWebGLBridge) {
        self.bridge = bridge
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WPEWebGLBridge.messageHandlerName else { return }
        let data: Data?
        if let dict = message.body as? [String: Any] {
            data = try? JSONSerialization.data(withJSONObject: dict)
        } else if let str = message.body as? String {
            data = str.data(using: .utf8)
        } else {
            data = nil
        }
        guard let payload = data else { return }
        Task { @MainActor [weak self] in
            self?.bridge?.handle(rawData: payload)
        }
    }
}
#endif
