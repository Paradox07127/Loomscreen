import Foundation
import WebKit

/// Collects CSP and JavaScript audit events without adding a script-message handler to production wallpaper views.
@MainActor
final class CSPViolationCollector: NSObject, WKScriptMessageHandler {

    struct Observation: Sendable {
        enum Kind: String, Sendable {
            case cspViolation
            case windowError
            case unhandledRejection
            case storageAccess
        }

        let kind: Kind
        let directive: String?
        let blockedURI: String?
        let message: String
        let sourceFile: String?
        let line: Int?
    }

    static let messageHandlerName = "lwCspAudit"

    private(set) var observations: [Observation] = []

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let kindRaw = dict["kind"] as? String,
              let kind = Observation.Kind(rawValue: kindRaw) else {
            return
        }
        let observation = Observation(
            kind: kind,
            directive: dict["directive"] as? String,
            blockedURI: dict["blockedURI"] as? String,
            message: (dict["message"] as? String) ?? "",
            sourceFile: dict["sourceFile"] as? String,
            line: dict["line"] as? Int
        )
        observations.append(observation)
    }

    /// Instruments CSP, JavaScript, and storage activity before page scripts execute.
    static let instrumentationSource: String = """
    (function() {
      const send = (payload) => {
        try { window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload); } catch (e) {}
      };

      document.addEventListener('securitypolicyviolation', (e) => {
        send({
          kind: 'cspViolation',
          directive: e.violatedDirective || e.effectiveDirective || null,
          blockedURI: e.blockedURI || null,
          message: 'CSP ' + (e.violatedDirective || '?') + ' blocked ' + (e.blockedURI || '?'),
          sourceFile: e.sourceFile || null,
          line: e.lineNumber || null
        });
      }, true);

      window.addEventListener('error', (e) => {
        send({
          kind: 'windowError',
          message: e.message || String(e.error) || '<unknown>',
          sourceFile: e.filename || null,
          line: e.lineno || null
        });
      });

      window.addEventListener('unhandledrejection', (e) => {
        let msg;
        try { msg = String(e.reason && e.reason.message ? e.reason.message : e.reason); }
        catch (_) { msg = '<unstringifiable rejection>'; }
        send({ kind: 'unhandledRejection', message: msg });
      });

      const reportStorage = (api) => send({ kind: 'storageAccess', directive: api, message: api });
      try {
        const origSetItem = Storage.prototype.setItem;
        Storage.prototype.setItem = function(...args) { reportStorage('localStorage.setItem'); return origSetItem.apply(this, args); };
        const origGetItem = Storage.prototype.getItem;
        Storage.prototype.getItem = function(...args) { reportStorage('localStorage.getItem'); return origGetItem.apply(this, args); };
      } catch (_) {}
      try {
        const origOpen = indexedDB.open.bind(indexedDB);
        indexedDB.open = function(...args) { reportStorage('indexedDB.open'); return origOpen(...args); };
      } catch (_) {}
      try {
        const cookieDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
        if (cookieDesc && cookieDesc.set) {
          Object.defineProperty(document, 'cookie', {
            get: cookieDesc.get,
            set: function(v) { reportStorage('document.cookie.set'); return cookieDesc.set.call(this, v); }
          });
        }
      } catch (_) {}
    })();
    """
}
