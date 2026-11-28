import Foundation
import SwiftUI
import UIKit
import WebKit

enum SidebarPluginMetaParser {
    private static let validPermissions: Set<String> = [
        "net",
        "clipboard.read",
        "clipboard.write",
        "storage",
        "toast",
        "tabs.read",
        "tabs.open",
        "page.read",
        "files.save",
        "contextMenu",
    ]

    private static let validContextMenus: Set<String> = [
        "selection",
        "image",
        "link",
        "page",
    ]

    static func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        var out = ""
        var prevDash = false
        for ch in lower {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_") {
                out.append(ch)
                prevDash = false
            } else if ch == "-" {
                if !out.isEmpty && !prevDash {
                    out.append("-")
                    prevDash = true
                }
            } else if !out.isEmpty && !prevDash {
                out.append("-")
                prevDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty {
            let hash = UInt32(truncatingIfNeeded: raw.hashValue)
            return "plugin-\(String(hash, radix: 36))"
        }
        return String(out.prefix(64))
    }

    static func parseHTML(_ rawHtml: String, fallbackName: String? = nil) throws -> (manifest: SidebarPluginManifest, html: String) {
        let html = rawHtml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !html.isEmpty else {
            throw NSError(domain: "PrismPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: "Plugin HTML cannot be empty"])
        }

        let pattern = #"<script\b[^>]*type=["']application/prism-manifest\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: rawHtml, range: NSRange(rawHtml.startIndex..., in: rawHtml)),
              let jsonRange = Range(match.range(at: 1), in: rawHtml) else {
            throw NSError(
                domain: "PrismPlugin",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing <script type=\"application/prism-manifest+json\">"]
            )
        }

        let jsonStr = String(rawHtml[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = jsonStr.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(domain: "PrismPlugin", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest JSON"])
        }

        let rawName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? (fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : rawName
        guard !name.isEmpty else {
            throw NSError(domain: "PrismPlugin", code: 4, userInfo: [NSLocalizedDescriptionKey: "Manifest missing required \"name\""])
        }

        let rawId = (obj["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = rawId.isEmpty ? slugify(name) : slugify(rawId)
        let rawVer = (obj["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = rawVer.isEmpty ? "1.0.0" : rawVer
        let description = (obj["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = (obj["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = (obj["icon"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let rawPerms = (obj["permissions"] as? [Any])?.compactMap { $0 as? String } ?? []
        var perms: [String] = []
        for p in rawPerms where validPermissions.contains(p) && !perms.contains(p) {
            perms.append(p)
        }

        let rawPlatforms = (obj["platforms"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var platforms: [String]? = nil
        if let rawPlatforms, !rawPlatforms.isEmpty {
            var pSet: [String] = []
            for p in rawPlatforms {
                if p == "desktop" || p == "pc" {
                    if !pSet.contains("desktop") { pSet.append("desktop") }
                } else if p == "ios" || p == "mobile" {
                    if !pSet.contains("ios") { pSet.append("ios") }
                }
            }
            if !pSet.isEmpty { platforms = pSet }
        }

        let hostPermissions = (obj["hostPermissions"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let rawCtx = (obj["contextMenus"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { validContextMenus.contains($0) }

        let manifest = SidebarPluginManifest(
            id: id,
            name: name,
            version: version,
            description: description,
            author: (author?.isEmpty == false) ? author : nil,
            icon: (icon?.isEmpty == false) ? String(icon!.prefix(16)) : nil,
            permissions: perms,
            platforms: platforms,
            hostPermissions: (hostPermissions?.isEmpty == false) ? hostPermissions : nil,
            contextMenus: (rawCtx?.isEmpty == false) ? Array(Set(rawCtx!)) : nil
        )
        return (manifest, rawHtml)
    }

    static func matchesIOS(_ manifest: SidebarPluginManifest) -> Bool {
        guard let platforms = manifest.platforms, !platforms.isEmpty else { return true }
        return platforms.contains("ios")
    }
}

final class SidebarPluginStorageStore {
    static let shared = SidebarPluginStorageStore()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.zzaoo.prism.plugin.storage")
    private var data: [String: [String: AnyCodableValue]] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("PrismCloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("sidebar-plugin-storage.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: AnyCodableValue]].self, from: raw) {
            data = decoded
        }
    }

    private func bucketKey(profileId: String, pluginId: String) -> String {
        "\(profileId)::\(pluginId)"
    }

    func getAll(profileId: String, pluginId: String) -> [String: Any] {
        queue.sync {
            let bucket = data[bucketKey(profileId: profileId, pluginId: pluginId)] ?? [:]
            var out: [String: Any] = [:]
            for (k, v) in bucket { out[k] = v.rawValue }
            return out
        }
    }

    func setValue(profileId: String, pluginId: String, key: String, value: Any?) {
        queue.async {
            let bk = self.bucketKey(profileId: profileId, pluginId: pluginId)
            var bucket = self.data[bk] ?? [:]
            if let wrapped = AnyCodableValue.from(value), !(value is NSNull) {
                bucket[key] = wrapped
            } else {
                bucket.removeValue(forKey: key)
            }
            self.data[bk] = bucket
            self.persistLocked()
        }
    }

    func removeValue(profileId: String, pluginId: String, key: String) {
        queue.async {
            let bk = self.bucketKey(profileId: profileId, pluginId: pluginId)
            self.data[bk]?.removeValue(forKey: key)
            self.persistLocked()
        }
    }

    func clear(profileId: String, pluginId: String) {
        queue.async {
            self.data.removeValue(forKey: self.bucketKey(profileId: profileId, pluginId: pluginId))
            self.persistLocked()
        }
    }

    func clearPlugin(_ pluginId: String) {
        queue.async {
            let suffix = "::\(pluginId)"
            self.data = self.data.filter { !$0.key.hasSuffix(suffix) }
            self.persistLocked()
        }
    }

    private func persistLocked() {
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }
}

struct SidebarPluginRunnerSheet: View {
    let plugin: SidebarPluginItem
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var toastText: String?

    private var activeProfile: BrowserProfile {
        syncEngine.profiles.first(where: { $0.id == tabManager.activeTab?.profileId }) ?? .defaultProfile
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                SidebarPluginWebView(
                    plugin: plugin,
                    profile: activeProfile,
                    isDark: colorScheme == .dark,
                    tabManager: tabManager,
                    onToast: { msg in
                        toastText = msg
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                            if toastText == msg { toastText = nil }
                        }
                    }
                )
                .ignoresSafeArea(.container, edges: .bottom)

                if let toastText {
                    Text(toastText)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .shadow(radius: 6)
                        .padding(.top, 10)
                        .transition(.opacity)
                }
            }
            .navigationTitle(plugin.manifest.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("关闭", "Close")) { dismiss() }
                }
            }
        }
    }
}

private struct SidebarPluginWebView: UIViewRepresentable {
    let plugin: SidebarPluginItem
    let profile: BrowserProfile
    let isDark: Bool
    let tabManager: TabManager
    let onToast: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(plugin: plugin, profile: profile, tabManager: tabManager, onToast: onToast)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.userContentController.add(context.coordinator, name: "prismPluginBridge")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        context.coordinator.webView = wv
        let html = buildInjectedHtml()
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func buildInjectedHtml() -> String {
        let metaObj: [String: Any] = [
            "id": plugin.manifest.id,
            "name": plugin.manifest.name,
            "version": plugin.manifest.version,
            "description": plugin.manifest.description,
            "icon": plugin.manifest.icon ?? "",
            "permissions": plugin.manifest.permissions,
        ]
        let ctxObj: [String: Any] = [
            "platform": "ios",
            "isMobile": true,
            "isDesktop": false,
            "profileId": profile.id,
            "profileName": profile.name,
            "theme": isDark ? "dark" : "light",
            "language": "zh-CN",
        ]
        let metaData = (try? JSONSerialization.data(withJSONObject: metaObj)) ?? Data("{}".utf8)
        let ctxData = (try? JSONSerialization.data(withJSONObject: ctxObj)) ?? Data("{}".utf8)
        let metaJSON = String(data: metaData, encoding: .utf8) ?? "{}"
        let ctxJSON = String(data: ctxData, encoding: .utf8) ?? "{}"
        let bg = isDark ? "#1e2024" : "#ffffff"
        let surf = isDark ? "#282a2e" : "#f8fafc"
        let surf2 = isDark ? "#32353b" : "#f1f5f9"
        let border = isDark ? "rgba(255,255,255,0.12)" : "#e2e8f0"
        let text = isDark ? "#f1f5f9" : "#0f172a"
        let muted = isDark ? "#94a3b8" : "#64748b"

        let bootstrap = """
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover" />
        <style id="prism-plugin-theme-vars">
        :root { color-scheme: \(isDark ? "dark" : "light"); --prism-bg:\(bg); --prism-surface:\(surf); --prism-surface-2:\(surf2); --prism-border:\(border); --prism-text:\(text); --prism-text-muted:\(muted); --prism-accent:#4f46e5; --prism-danger:#ef4444; --prism-success:#10b981; }
        html,body { margin:0; padding:0; background:var(--prism-bg); color:var(--prism-text); font-family:-apple-system,BlinkMacSystemFont,sans-serif; font-size:13px; line-height:1.5; }
        .prism-app { padding:12px; padding-bottom:calc(20px + env(safe-area-inset-bottom,0px)); display:flex; flex-direction:column; gap:10px; }
        .prism-card { background:var(--prism-surface); border:1px solid var(--prism-border); border-radius:12px; padding:12px; }
        .prism-row { display:flex; align-items:center; gap:8px; }
        .prism-muted { color:var(--prism-text-muted); font-size:12px; }
        .prism-btn { min-height:36px; padding:0 12px; border-radius:9px; border:1px solid var(--prism-border); background:var(--prism-surface-2); color:var(--prism-text); font-size:12.5px; font-weight:600; touch-action:manipulation; }
        .prism-btn-primary { background:var(--prism-accent); border-color:transparent; color:#fff; }
        .prism-input,.prism-textarea,.prism-select { width:100%; box-sizing:border-box; border-radius:9px; border:1px solid var(--prism-border); background:var(--prism-bg); color:var(--prism-text); font-size:13px; padding:8px 10px; }
        .prism-input,.prism-select { min-height:36px; }
        .prism-textarea { min-height:88px; }
        .prism-dropzone { border:1.5px dashed var(--prism-accent); border-radius:12px; padding:18px 12px; text-align:center; background:var(--prism-surface-2); }
        .prism-badge { display:inline-flex; align-items:center; padding:2px 8px; border-radius:999px; font-size:11px; font-weight:600; background:var(--prism-surface-2); color:var(--prism-text-muted); border:1px solid var(--prism-border); }
        .prism-code { font-family:ui-monospace,Menlo,monospace; font-size:11.5px; background:var(--prism-surface-2); border:1px solid var(--prism-border); border-radius:8px; padding:8px 10px; white-space:pre-wrap; word-break:break-all; margin:0; }
        </style>
        <script>
        (function(){
          'use strict';
          const __META = Object.freeze(\(metaJSON));
          const __CTX = Object.freeze(\(ctxJSON));
          const __pending = new Map();
          let __seq = 0;
          window.__prismPluginReply = function(id, res) {
            const e = __pending.get(id);
            if (!e) return;
            __pending.delete(id);
            if (!res || !res.ok) e.reject(new Error((res && res.error) || 'Plugin RPC failed'));
            else e.resolve(res.data);
          };
          function callHost(method, params) {
            return new Promise((resolve, reject) => {
              const id = 'ios_' + (++__seq) + '_' + Date.now();
              __pending.set(id, { resolve, reject });
              window.webkit.messageHandlers.prismPluginBridge.postMessage({ id, method, params: params || {} });
            });
          }
          function uint8ToB64(bytes) {
            const C = 0x8000, parts = [];
            for (let i = 0; i < bytes.length; i += C) parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + C)));
            return btoa(parts.join(''));
          }
          function b64ToUint8(b64) {
            const bin = atob(b64), out = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
            return out;
          }
          async function serializeBody(body, headers) {
            if (body === undefined || body === null) return {};
            if (typeof FormData !== 'undefined' && body instanceof FormData) {
              const multipart = [];
              for (const entry of body.entries()) {
                const name = String(entry[0]), val = entry[1];
                if (typeof Blob !== 'undefined' && val instanceof Blob) {
                  const ab = await val.arrayBuffer();
                  multipart.push({ name, filename: val.name || 'blob', contentType: val.type || 'application/octet-stream', base64: uint8ToB64(new Uint8Array(ab)) });
                } else {
                  multipart.push({ name, value: String(val) });
                }
              }
              return { multipart };
            }
            if (typeof Blob !== 'undefined' && body instanceof Blob) {
              const ab = await body.arrayBuffer();
              return { bodyBase64: uint8ToB64(new Uint8Array(ab)), bodyContentType: body.type || undefined };
            }
            if (body instanceof ArrayBuffer) return { bodyBase64: uint8ToB64(new Uint8Array(body)) };
            if (ArrayBuffer.isView(body)) return { bodyBase64: uint8ToB64(new Uint8Array(body.buffer, body.byteOffset, body.byteLength)) };
            return { data: String(body) };
          }
          async function netRequest(optsOrUrl, maybeOpts) {
            const opts = typeof optsOrUrl === 'string' ? Object.assign({}, maybeOpts || {}, { url: optsOrUrl }) : Object.assign({}, optsOrUrl || {});
            const headers = Object.assign({}, opts.headers || {});
            let bodyPayload = {};
            if (opts.json !== undefined) {
              headers['Content-Type'] = headers['Content-Type'] || 'application/json';
              bodyPayload = { data: JSON.stringify(opts.json) };
            } else if (opts.body !== undefined || opts.data !== undefined) {
              const raw = opts.body !== undefined ? opts.body : opts.data;
              bodyPayload = await serializeBody(raw, headers);
            }
            const res = await callHost('net.request', Object.assign({ method: opts.method || 'GET', url: String(opts.url), headers, timeout: opts.timeout || 30000, responseType: opts.responseType }, bodyPayload));
            const rt = String(opts.responseType || '').toLowerCase();
            let parsedData = res.responseText;
            if (rt === 'arraybuffer' && res.base64Body) parsedData = b64ToUint8(res.base64Body).buffer;
            else if (rt === 'blob' && res.base64Body) parsedData = new Blob([b64ToUint8(res.base64Body)]);
            else if (rt === 'json' || (!rt && res.headers && String(res.headers['content-type'] || '').includes('application/json'))) {
              try { parsedData = JSON.parse(res.responseText); } catch {}
            }
            return { ok: res.status >= 200 && res.status < 300, status: res.status, statusText: res.statusText || '', finalUrl: res.finalUrl || String(opts.url), headers: res.headers || {}, responseHeaders: res.responseHeaders || '', responseText: res.responseText || '', data: parsedData };
          }
          window.prismPlugin = Object.freeze({
            meta: __META,
            get context() { return __CTX; },
            onContextChange: () => () => {},
            onAction: () => () => {},
            getLastAction: () => null,
            net: Object.freeze({ request: netRequest, fetch: netRequest }),
            clipboard: Object.freeze({
              writeText: (text) => callHost('clipboard.writeText', { text: String(text ?? '') }),
              readText: () => callHost('clipboard.readText', {}),
              readImage: async () => {
                const res = await callHost('clipboard.readImage', {});
                if (!res) return null;
                const blob = new Blob([b64ToUint8(res.base64)], { type: res.mime || 'image/png' });
                let file = blob;
                try { file = new File([blob], res.filename || 'clipboard.png', { type: res.mime || 'image/png' }); } catch {}
                return Object.assign({}, res, { blob, file });
              },
              writeImage: () => Promise.resolve(false),
            }),
            storage: Object.freeze({
              get: (key, d) => callHost('storage.get', { key: String(key), defaultValue: d }),
              set: (key, value) => callHost('storage.set', { key: String(key), value }),
              remove: (key) => callHost('storage.remove', { key: String(key) }),
              listKeys: () => callHost('storage.listKeys', {}),
              getAll: () => callHost('storage.getAll', {}),
              clear: () => callHost('storage.clear', {}),
            }),
            ui: Object.freeze({ toast: (m, k) => callHost('ui.toast', { message: String(m ?? ''), kind: k || 'info' }) }),
            tabs: Object.freeze({
              getActive: () => callHost('tabs.getActive', {}),
              list: () => callHost('tabs.list', {}),
              open: (url, o) => callHost('tabs.open', { url: String(url), active: !(o && o.active === false) }),
            }),
            page: Object.freeze({
              getMarkdown: () => callHost('page.getMarkdown', {}),
              getSelection: () => callHost('page.getSelection', {}),
              captureScreenshot: () => callHost('page.captureScreenshot', {}),
            }),
            files: Object.freeze({
              save: () => Promise.resolve({ ok: false, error: 'Use share sheet on iOS' }),
            }),
          });
        })();
        </script>
        """

        if let headRange = plugin.html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var copy = plugin.html
            copy.insert(contentsOf: "\n" + bootstrap, at: headRange.upperBound)
            return copy
        }
        return "<!DOCTYPE html><html><head>\(bootstrap)</head><body>\(plugin.html)</body></html>"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let plugin: SidebarPluginItem
        let profile: BrowserProfile
        let tabManager: TabManager
        let onToast: (String) -> Void
        weak var webView: WKWebView?

        init(plugin: SidebarPluginItem, profile: BrowserProfile, tabManager: TabManager, onToast: @escaping (String) -> Void) {
            self.plugin = plugin
            self.profile = profile
            self.tabManager = tabManager
            self.onToast = onToast
        }

        private func hasPerm(_ p: String) -> Bool {
            plugin.manifest.permissions.contains(p)
        }

        private func reply(_ id: String, ok: Bool, data: Any? = nil, error: String? = nil) {
            var res: [String: Any] = ["ok": ok]
            if let data { res["data"] = data }
            if let error { res["error"] = error }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: res),
                  let jsonStr = String(data: jsonData, encoding: .utf8),
                  let idData = try? JSONSerialization.data(withJSONObject: [id]),
                  let idArr = String(data: idData, encoding: .utf8) else { return }
            let js = "window.__prismPluginReply && window.__prismPluginReply((\(idArr))[0], \(jsonStr));"
            Task { @MainActor in
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let id = body["id"] as? String,
                  let method = body["method"] as? String else { return }
            let params = body["params"] as? [String: Any] ?? [:]

            switch method {
            case "clipboard.writeText":
                guard hasPerm("clipboard.write") else { return reply(id, ok: false, error: "Permission clipboard.write denied") }
                UIPasteboard.general.string = params["text"] as? String ?? ""
                reply(id, ok: true, data: true)

            case "clipboard.readText":
                guard hasPerm("clipboard.read") else { return reply(id, ok: false, error: "Permission clipboard.read denied") }
                reply(id, ok: true, data: UIPasteboard.general.string ?? "")

            case "clipboard.readImage":
                guard hasPerm("clipboard.read") else { return reply(id, ok: false, error: "Permission clipboard.read denied") }
                if let img = UIPasteboard.general.image, let png = img.pngData() {
                    let b64 = png.base64EncodedString()
                    reply(id, ok: true, data: [
                        "base64": b64,
                        "dataUrl": "data:image/png;base64,\(b64)",
                        "mime": "image/png",
                        "width": Int(img.size.width),
                        "height": Int(img.size.height),
                        "sizeBytes": png.count,
                        "filename": "clipboard.png",
                    ])
                } else {
                    reply(id, ok: true, data: NSNull())
                }

            case "storage.get":
                guard hasPerm("storage") else { return reply(id, ok: false, error: "Permission storage denied") }
                let key = params["key"] as? String ?? ""
                let all = SidebarPluginStorageStore.shared.getAll(profileId: profile.id, pluginId: plugin.id)
                reply(id, ok: true, data: all[key] ?? params["defaultValue"] ?? NSNull())

            case "storage.set":
                guard hasPerm("storage") else { return reply(id, ok: false, error: "Permission storage denied") }
                let key = params["key"] as? String ?? ""
                SidebarPluginStorageStore.shared.setValue(profileId: profile.id, pluginId: plugin.id, key: key, value: params["value"])
                reply(id, ok: true, data: true)

            case "storage.remove":
                guard hasPerm("storage") else { return reply(id, ok: false, error: "Permission storage denied") }
                SidebarPluginStorageStore.shared.removeValue(profileId: profile.id, pluginId: plugin.id, key: params["key"] as? String ?? "")
                reply(id, ok: true, data: true)

            case "storage.listKeys":
                guard hasPerm("storage") else { return reply(id, ok: false, error: "Permission storage denied") }
                let all = SidebarPluginStorageStore.shared.getAll(profileId: profile.id, pluginId: plugin.id)
                reply(id, ok: true, data: Array(all.keys))

            case "storage.getAll":
                guard hasPerm("storage") else { return reply(id, ok: false, error: "Permission storage denied") }
                reply(id, ok: true, data: SidebarPluginStorageStore.shared.getAll(profileId: profile.id, pluginId: plugin.id))

            case "storage.clear":
                guard hasPerm("storage") else { return reply(id, ok: false, error: "Permission storage denied") }
                SidebarPluginStorageStore.shared.clear(profileId: profile.id, pluginId: plugin.id)
                reply(id, ok: true, data: true)

            case "ui.toast":
                guard hasPerm("toast") else { return reply(id, ok: false, error: "Permission toast denied") }
                let msg = params["message"] as? String ?? ""
                Task { @MainActor in self.onToast(msg) }
                reply(id, ok: true, data: true)

            case "tabs.getActive":
                guard hasPerm("tabs.read") else { return reply(id, ok: false, error: "Permission tabs.read denied") }
                Task { @MainActor in
                    if let t = self.tabManager.activeTab {
                        self.reply(id, ok: true, data: ["id": t.id, "title": t.title, "url": t.urlString, "profileId": t.profileId])
                    } else {
                        self.reply(id, ok: true, data: NSNull())
                    }
                }

            case "tabs.list":
                guard hasPerm("tabs.read") else { return reply(id, ok: false, error: "Permission tabs.read denied") }
                Task { @MainActor in
                    let list = self.tabManager.tabs
                        .filter { $0.profileId == self.profile.id }
                        .map { ["id": $0.id, "title": $0.title, "url": $0.urlString, "profileId": $0.profileId] }
                    self.reply(id, ok: true, data: list)
                }

            case "tabs.open":
                guard hasPerm("tabs.open") else { return reply(id, ok: false, error: "Permission tabs.open denied") }
                let rawUrl = (params["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: rawUrl), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    return reply(id, ok: false, error: "Invalid URL")
                }
                let activate = (params["active"] as? Bool) ?? true
                Task { @MainActor in
                    _ = self.tabManager.createTab(url: url, profileId: self.profile.id, activate: activate)
                    self.reply(id, ok: true, data: true)
                }

            case "page.getSelection":
                guard hasPerm("page.read") else { return reply(id, ok: false, error: "Permission page.read denied") }
                Task { @MainActor in
                    guard let activeWv = self.tabManager.activeTab?.webView else {
                        return self.reply(id, ok: true, data: "")
                    }
                    activeWv.evaluateJavaScript("String(window.getSelection ? window.getSelection().toString() : '')") { val, _ in
                        self.reply(id, ok: true, data: (val as? String) ?? "")
                    }
                }

            case "page.getMarkdown":
                guard hasPerm("page.read") else { return reply(id, ok: false, error: "Permission page.read denied") }
                Task { @MainActor in
                    guard let activeWv = self.tabManager.activeTab?.webView else {
                        return self.reply(id, ok: true, data: ["ok": false, "error": "No active page"])
                    }
                    let js = "(() => ({ ok: true, title: document.title, url: location.href, markdown: (document.body && document.body.innerText) || '' }))()"
                    activeWv.evaluateJavaScript(js) { val, err in
                        if let dict = val as? [String: Any] {
                            self.reply(id, ok: true, data: dict)
                        } else {
                            self.reply(id, ok: true, data: ["ok": false, "error": err?.localizedDescription ?? "Extract failed"])
                        }
                    }
                }

            case "net.request":
                guard hasPerm("net") else { return reply(id, ok: false, error: "Permission net denied") }
                handleNetRequest(id: id, params: params)

            default:
                reply(id, ok: false, error: "Unsupported method on iOS: \(method)")
            }
        }

        private func handleNetRequest(id: String, params: [String: Any]) {
            let rawUrl = params["url"] as? String ?? ""
            guard let url = URL(string: rawUrl), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return reply(id, ok: false, error: "Invalid URL")
            }
            var req = URLRequest(url: url)
            req.httpMethod = (params["method"] as? String ?? "GET").uppercased()
            let timeoutSec = min(120.0, max(1.0, ((params["timeout"] as? Double) ?? 30000.0) / 1000.0))
            req.timeoutInterval = timeoutSec

            if let headers = params["headers"] as? [String: String] {
                for (k, v) in headers where k.lowercased() != "content-length" && k.lowercased() != "host" {
                    req.setValue(v, forHTTPHeaderField: k)
                }
            }

            if let multipart = params["multipart"] as? [[String: Any]] {
                let boundary = "----PrismFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                var bodyData = Data()
                for field in multipart {
                    guard let name = field["name"] as? String else { continue }
                    if let b64 = field["base64"] as? String, let fileData = Data(base64Encoded: b64) {
                        let fname = (field["filename"] as? String) ?? "blob"
                        let ctype = (field["contentType"] as? String) ?? "application/octet-stream"
                        bodyData.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fname)\"\r\nContent-Type: \(ctype)\r\n\r\n".data(using: .utf8)!)
                        bodyData.append(fileData)
                        bodyData.append("\r\n".data(using: .utf8)!)
                    } else {
                        let val = (field["value"] as? String) ?? ""
                        bodyData.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(val)\r\n".data(using: .utf8)!)
                    }
                }
                bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)
                req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                req.httpBody = bodyData
            } else if let b64 = params["bodyBase64"] as? String, let bin = Data(base64Encoded: b64) {
                req.httpBody = bin
            } else if let dataStr = params["data"] as? String, req.httpMethod != "GET", req.httpMethod != "HEAD" {
                req.httpBody = dataStr.data(using: .utf8)
            }

            let rt = (params["responseType"] as? String ?? "").lowercased()
            URLSession.shared.dataTask(with: req) { data, response, err in
                if let err {
                    return self.reply(id, ok: false, error: err.localizedDescription)
                }
                let http = response as? HTTPURLResponse
                var headerMap: [String: String] = [:]
                var rawLines: [String] = []
                if let fields = http?.allHeaderFields {
                    for (k, v) in fields {
                        let ks = "\(k)"
                        let vs = "\(v)"
                        headerMap[ks.lowercased()] = vs
                        rawLines.append("\(ks): \(vs)")
                    }
                }
                let bodyBytes = data ?? Data()
                var out: [String: Any] = [
                    "status": http?.statusCode ?? 0,
                    "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
                    "finalUrl": response?.url?.absoluteString ?? rawUrl,
                    "headers": headerMap,
                    "responseHeaders": rawLines.joined(separator: "\r\n"),
                ]
                if rt == "arraybuffer" || rt == "blob" {
                    out["responseText"] = ""
                    out["base64Body"] = bodyBytes.base64EncodedString()
                } else {
                    out["responseText"] = String(data: bodyBytes, encoding: .utf8) ?? ""
                }
                self.reply(id, ok: true, data: out)
            }.resume()
        }
    }
}
