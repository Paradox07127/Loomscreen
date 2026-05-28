import Foundation
import WebKit

/// Test-only `WKScriptMessageHandler` that receives violation events from the
/// instrumented WKWebView and aggregates them into a per-project report.
///
/// Production code keeps the "no `WKScriptMessageHandler` on the HTML
/// wallpaper path" invariant; this collector is wired only from the audit
/// suite. It must stay in the test target.
@MainActor
final class CSPViolationCollector: NSObject, WKScriptMessageHandler {

    /// One observation from the page — either a CSP violation, a JS error,
    /// or a runtime exception. Tagged so the report distinguishes "policy
    /// violation" from "broken JS that the policy probably caused".
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

    /// `WKUserScript` source. Installed at `documentStart` so the listeners
    /// are attached before any wallpaper script runs.
    ///
    /// The script also monkey-patches storage APIs (localStorage / IndexedDB
    /// / `document.cookie`) — not to block them (Report-Only mode wouldn't
    /// honor `script-src` blocks anyway), but to surface "did this corpus
    /// member actually try to use storage?" alongside the CSP violations.
    /// The plan's belt-and-suspenders storage stub is conditional on this
    /// audit reporting ≥99 % storage-free.
    static let instrumentationSource: String = """
    (function() {
      const send = (payload) => {
        try { window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload); } catch (e) { /* swallow */ }
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

      // Storage probes — call once at documentStart to fingerprint the
      // page's intent. We don't block; we just witness.
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
