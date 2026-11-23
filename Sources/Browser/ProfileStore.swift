import CryptoKit
import Foundation
import Network
import WebKit

@MainActor
final class ProfileDataStoreRegistry {
    static let shared = ProfileDataStoreRegistry()
    private var cache: [String: WKWebsiteDataStore] = [:]

    func dataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
        if profile.id == "default" {
            let store = WKWebsiteDataStore.default()
            applyProxy(for: profile, to: store)
            return store
        }
        if let existing = cache[profile.id] {
            applyProxy(for: profile, to: existing)
            return existing
        }
        let uuid = deterministicUUID(for: profile.id)
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        applyProxy(for: profile, to: store)
        cache[profile.id] = store
        return store
    }

    func applyProxy(for profile: BrowserProfile, to store: WKWebsiteDataStore) {
        guard profile.proxyMode == .custom else {
            store.proxyConfigurations = []
            return
        }
        let raw = profile.proxyRules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            store.proxyConfigurations = []
            return
        }

        // Parse scheme/rule prefix like http=host:port;https=... or socks5://user:pass@host:port
        var candidate = (raw.components(separatedBy: ";").first ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var isSocks = false
        if let eqIdx = candidate.firstIndex(of: "=") {
            let prefix = candidate[..<eqIdx].lowercased()
            if prefix.contains("socks") {
                isSocks = true
            }
            candidate = String(candidate[candidate.index(after: eqIdx)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lower = candidate.lowercased()
        if lower.hasPrefix("socks5://") || lower.hasPrefix("socks://") {
            isSocks = true
        }

        let normalizedURLString = candidate.contains("://") ? candidate : "http://\(candidate)"
        guard let components = URLComponents(string: normalizedURLString),
              let host = components.host, !host.isEmpty,
              let portInt = components.port,
              let portNum = UInt16(exactly: portInt),
              let port = NWEndpoint.Port(rawValue: portNum) else {
            store.proxyConfigurations = []
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        var config = isSocks
            ? ProxyConfiguration(socksv5Proxy: endpoint)
            : ProxyConfiguration(httpCONNECTProxy: endpoint)
        if let user = components.user, !user.isEmpty {
            config.applyCredential(username: user, password: components.password ?? "")
        }
        store.proxyConfigurations = [config]
    }

    func fingerprintUserScript(for profile: BrowserProfile) -> WKUserScript? {
        guard profile.fingerprint.canvasNoise || (profile.fingerprint.language?.isEmpty == false) else {
            return nil
        }
        let noiseFlag = profile.fingerprint.canvasNoise ? "true" : "false"
        let seed = UInt32(truncatingIfNeeded: profile.id.hashValue & 0x7FFF) + 17
        let js = """
        (function() {
          if (window.__prismFpApplied) return;
          window.__prismFpApplied = true;
          try {
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
          } catch (e) {}
          if (\(noiseFlag)) {
            try {
              const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
              HTMLCanvasElement.prototype.toDataURL = function() {
                try {
                  const ctx = this.getContext('2d');
                  if (ctx && this.width > 2 && this.height > 2) {
                    const img = ctx.getImageData(0, 0, 1, 1);
                    img.data[0] = (img.data[0] + (\(seed) % 3)) % 255;
                    ctx.putImageData(img, 0, 0);
                  }
                } catch (e) {}
                return origToDataURL.apply(this, arguments);
              };
            } catch (e) {}
          }
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private func deterministicUUID(for id: String) -> UUID {
        let hash = SHA256.hash(data: Data("prism-profile:\(id)".utf8))
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
