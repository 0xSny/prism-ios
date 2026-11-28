import Foundation
import WebKit

enum UserscriptMetaParser {
    private static let validRunAt: Set<String> = [
        "document-start",
        "document-body",
        "document-end",
        "document-idle",
    ]

    static func parseHeader(_ code: String) -> UserscriptMeta {
        var name = ""
        var localizedName = ""
        var namespace: String?
        var version = "1.0.0"
        var description = ""
        var localizedDescription = ""
        var author: String?
        var icon: String?
        var runAt = "document-idle"
        var noFrames = false
        var downloadURL: String?
        var updateURL: String?
        var homepageURL: String?
        var matches: [String] = []
        var includes: [String] = []
        var excludes: [String] = []
        var grants: [String] = []
        var requires: [String] = []
        var resources: [String: String] = [:]
        var platformSet = Set<String>()

        if let startRange = code.range(of: "==UserScript==", options: .caseInsensitive),
           let endRange = code.range(of: "==/UserScript==", options: .caseInsensitive, range: startRange.upperBound..<code.endIndex) {
            let block = String(code[startRange.upperBound..<endRange.lowerBound])
            let lines = block.components(separatedBy: .newlines)
            for rawLine in lines {
                let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
                guard trimmedLine.hasPrefix("//") else { continue }
                let afterSlash = trimmedLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
                guard afterSlash.hasPrefix("@") else { continue }
                let body = afterSlash.dropFirst()
                let parts = body.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\t" })
                let directiveLower = String(parts.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let val = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

                switch directiveLower {
                case "name":
                    if name.isEmpty && !val.isEmpty { name = val }
                case "name:zh-cn", "name:zh":
                    if !val.isEmpty { localizedName = val }
                case "namespace":
                    if !val.isEmpty { namespace = val }
                case "version":
                    if !val.isEmpty { version = val }
                case "description":
                    if description.isEmpty && !val.isEmpty { description = val }
                case "description:zh-cn", "description:zh":
                    if !val.isEmpty { localizedDescription = val }
                case "author":
                    if !val.isEmpty { author = val }
                case "icon", "iconurl", "defaulticon":
                    if val.lowercased().hasPrefix("http://") || val.lowercased().hasPrefix("https://") { icon = val }
                case "match":
                    if !val.isEmpty && !matches.contains(val) { matches.append(val) }
                case "include":
                    if !val.isEmpty && !includes.contains(val) { includes.append(val) }
                case "exclude", "exclude-match":
                    if !val.isEmpty && !excludes.contains(val) { excludes.append(val) }
                case "grant":
                    if !val.isEmpty && !grants.contains(val) { grants.append(val) }
                case "require":
                    if !val.isEmpty && !requires.contains(val) { requires.append(val) }
                case "resource":
                    let resParts = val.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                    if resParts.count == 2 {
                        resources[String(resParts[0])] = String(resParts[1])
                    }
                case "run-at":
                    if validRunAt.contains(val) { runAt = val }
                case "noframes":
                    noFrames = true
                case "downloadurl":
                    if !val.isEmpty { downloadURL = val }
                case "updateurl":
                    if !val.isEmpty { updateURL = val }
                case "homepageurl", "homepage":
                    if !val.isEmpty { homepageURL = val }
                case "prism-platform":
                    let tokens = val.lowercased().components(separatedBy: CharacterSet(charactersIn: ", \t"))
                    for tok in tokens where !tok.isEmpty {
                        if tok == "desktop" || tok == "pc" {
                            platformSet.insert("desktop")
                        } else if tok == "ios" || tok == "mobile" {
                            platformSet.insert("ios")
                        } else if tok == "all" || tok == "*" {
                            platformSet.insert("desktop")
                            platformSet.insert("ios")
                        }
                    }
                default:
                    break
                }
            }
        }

        let platforms: [String]? = (platformSet.count == 1) ? Array(platformSet) : nil

        return UserscriptMeta(
            name: localizedName.isEmpty ? (name.isEmpty ? "Untitled Userscript" : name) : localizedName,
            namespace: namespace,
            version: version,
            description: localizedDescription.isEmpty ? description : localizedDescription,
            author: author,
            icon: icon,
            matches: matches,
            includes: includes,
            excludes: excludes,
            grants: grants,
            requires: requires,
            resources: resources,
            runAt: runAt,
            noFrames: noFrames,
            platforms: platforms,
            downloadURL: downloadURL,
            updateURL: updateURL,
            homepageURL: homepageURL
        )
    }

    static func matchesPlatform(_ meta: UserscriptMeta, platform: String = "ios") -> Bool {
        guard let platforms = meta.platforms, !platforms.isEmpty else { return true }
        return platforms.contains(platform)
    }

    static func matchesURL(_ meta: UserscriptMeta, urlString: String) -> Bool {
        guard let parsed = URL(string: urlString),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let href = parsed.absoluteString
        for ex in meta.excludes {
            if matchPattern(ex, urlString: href, parsed: parsed) { return false }
        }
        for m in meta.matches {
            if matchPattern(m, urlString: href, parsed: parsed) { return true }
        }
        for inc in meta.includes {
            if matchPattern(inc, urlString: href, parsed: parsed) { return true }
        }
        return false
    }

    private static func matchPattern(_ rawPattern: String, urlString: String, parsed: URL) -> Bool {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "*" || trimmed == "<all_urls>" || trimmed == "*://*/*" {
            return true
        }
        if trimmed.hasPrefix("/"), let lastSlash = trimmed.lastIndex(of: "/"), lastSlash > trimmed.startIndex {
            let body = String(trimmed[trimmed.index(after: trimmed.startIndex)..<lastSlash])
            let flags = String(trimmed[trimmed.index(after: lastSlash)...])
            var opts: NSRegularExpression.Options = []
            if flags.contains("i") { opts.insert(.caseInsensitive) }
            if flags.contains("m") { opts.insert(.anchorsMatchLines) }
            if flags.contains("s") { opts.insert(.dotMatchesLineSeparators) }
            if let re = try? NSRegularExpression(pattern: body, options: opts) {
                let ns = urlString as NSString
                return re.firstMatch(in: urlString, range: NSRange(location: 0, length: ns.length)) != nil
            }
            return false
        }

        if let schemeSplit = trimmed.range(of: "://") {
            let schemePat = String(trimmed[..<schemeSplit.lowerBound]).lowercased()
            let rest = String(trimmed[schemeSplit.upperBound...])
            let slashIdx = rest.firstIndex(of: "/") ?? rest.endIndex
            let hostPat = String(rest[..<slashIdx]).lowercased()
            let pathPat = slashIdx < rest.endIndex ? String(rest[slashIdx...]) : "/*"

            if schemePat != "*", parsed.scheme?.lowercased() != schemePat {
                return false
            }
            let actualHost = (parsed.host ?? "").lowercased()
            if hostPat == "*" {
                // Match any host
            } else if hostPat.hasPrefix("*.") {
                let bare = String(hostPat.dropFirst(2))
                if actualHost != bare && !actualHost.hasSuffix(".\(bare)") {
                    return false
                }
            } else if hostPat.contains("*") {
                let regexStr = "^\(wildcardToRegex(hostPat))$"
                if actualHost.range(of: regexStr, options: [.regularExpression, .caseInsensitive]) == nil {
                    return false
                }
            } else {
                let patHostNoPort = hostPat.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
                if actualHost != patHostNoPort {
                    return false
                }
            }

            let pathAndQuery = (parsed.path.isEmpty ? "/" : parsed.path) + (parsed.query.map { "?\($0)" } ?? "")
            let fullPath = pathAndQuery + (parsed.fragment.map { "#\($0)" } ?? "")
            let pathRegex = "^\(wildcardToRegex(pathPat))$"
            return fullPath.range(of: pathRegex, options: .regularExpression) != nil
                || pathAndQuery.range(of: pathRegex, options: .regularExpression) != nil
        }

        let wildcardRegex = "^\(wildcardToRegex(trimmed))$"
        return urlString.range(of: wildcardRegex, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func wildcardToRegex(_ pattern: String) -> String {
        pattern
            .split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
    }
}

final class UserscriptStorageStore {
    static let shared = UserscriptStorageStore()
    private let fileURL: URL
    private var data: [String: [String: [String: AnyCodableValue]]] = [:]
    private let lock = NSLock()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = base.appendingPathComponent("prism-userscript-storage.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: [String: AnyCodableValue]]].self, from: raw) {
            self.data = decoded
        }
    }

    func getAll(profileId: String, scriptId: String) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let bucket = data[profileId]?[scriptId] ?? [:]
        return bucket.mapValues { $0.rawValue }
    }

    func setValue(profileId: String, scriptId: String, key: String, value: Any?) {
        lock.lock()
        if data[profileId] == nil { data[profileId] = [:] }
        if data[profileId]?[scriptId] == nil { data[profileId]?[scriptId] = [:] }
        if let wrapped = AnyCodableValue.from(value) {
            data[profileId]?[scriptId]?[key] = wrapped
        } else {
            data[profileId]?[scriptId]?.removeValue(forKey: key)
        }
        let snapshot = data
        lock.unlock()
        persist(snapshot)
    }

    func deleteValue(profileId: String, scriptId: String, key: String) {
        lock.lock()
        data[profileId]?[scriptId]?.removeValue(forKey: key)
        let snapshot = data
        lock.unlock()
        persist(snapshot)
    }

    func clearScript(_ scriptId: String) {
        lock.lock()
        for pid in data.keys {
            data[pid]?.removeValue(forKey: scriptId)
        }
        let snapshot = data
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: [String: [String: AnyCodableValue]]]) {
        if let encoded = try? JSONEncoder().encode(snapshot) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }
}

enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dict([String: AnyCodableValue])
    case null

    var rawValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let arr): return arr.map { $0.rawValue }
        case .dict(let d): return d.mapValues { $0.rawValue }
        case .null: return NSNull()
        }
    }

    static func from(_ raw: Any?) -> AnyCodableValue? {
        guard let raw else { return nil }
        if raw is NSNull { return .null }
        if let b = raw as? Bool { return .bool(b) }
        if let i = raw as? Int { return .int(i) }
        if let d = raw as? Double { return .double(d) }
        if let s = raw as? String { return .string(s) }
        if let arr = raw as? [Any] {
            return .array(arr.compactMap { from($0) })
        }
        if let d = raw as? [String: Any] {
            var out: [String: AnyCodableValue] = [:]
            for (k, v) in d {
                if let wrapped = from(v) { out[k] = wrapped }
            }
            return .dict(out)
        }
        return .string(String(describing: raw))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let arr = try? container.decode([AnyCodableValue].self) { self = .array(arr) }
        else if let dict = try? container.decode([String: AnyCodableValue].self) { self = .dict(dict) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dict(let v): try container.encode(v)
        }
    }
}

final class UserscriptRuntime {
    static let shared = UserscriptRuntime()
    private init() {}

    func buildWKUserScripts(
        scripts: [UserscriptItem],
        profileId: String,
        urlString: String
    ) -> [WKUserScript] {
        guard !scripts.isEmpty else { return [] }
        var result: [WKUserScript] = []

        for item in scripts {
            guard item.enabled else { continue }
            if item.disabledProfileIds?.contains(profileId) == true { continue }
            guard UserscriptMetaParser.matchesPlatform(item.meta, platform: "ios") else { continue }
            if !urlString.isEmpty && !UserscriptMetaParser.matchesURL(item.meta, urlString: urlString) {
                continue
            }

            let isMainWorld = item.meta.grants.count == 1 && item.meta.grants[0] == "none"
            let world: WKContentWorld = isMainWorld ? .page : .defaultClient
            let injectionTime: WKUserScriptInjectionTime = (item.meta.runAt == "document-start" || item.meta.runAt == "document-body")
                ? .atDocumentStart
                : .atDocumentEnd
            let wrapped = wrapExecutionCode(item: item, profileId: profileId, isMainWorld: isMainWorld)
            result.append(WKUserScript(
                source: wrapped,
                injectionTime: injectionTime,
                forMainFrameOnly: item.meta.noFrames,
                in: world
            ))
        }
        return result
    }

    private func wrapExecutionCode(item: UserscriptItem, profileId: String, isMainWorld: Bool) -> String {
        let infoDict: [String: Any] = [
            "script": [
                "name": item.meta.name,
                "namespace": item.meta.namespace ?? "prism-userscript",
                "version": item.meta.version,
                "description": item.meta.description,
                "matches": item.meta.matches,
                "includes": item.meta.includes,
                "excludes": item.meta.excludes,
                "grants": item.meta.grants,
                "run-at": item.meta.runAt,
            ],
            "scriptHandler": "Prism Tampermonkey",
            "version": "1.1.6",
            "prism": [
                "platform": "ios",
                "isMobile": true,
                "isDesktop": false,
                "profileId": profileId,
            ],
        ]
        let infoData = (try? JSONSerialization.data(withJSONObject: infoDict)) ?? Data("{}".utf8)
        let infoJson = String(data: infoData, encoding: .utf8) ?? "{}"

        if isMainWorld {
            return """
            (function() {
              'use strict';
              const GM_info = \(infoJson);
              const unsafeWindow = window;
              const GM_addStyle = function(css) {
                try {
                  const text = String(css ?? '');
                  if (typeof CSSStyleSheet === 'function' && 'adoptedStyleSheets' in document) {
                    const sheet = new CSSStyleSheet();
                    sheet.replaceSync(text);
                    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
                    return sheet;
                  }
                  const st = document.createElement('style');
                  st.textContent = text;
                  (document.head || document.documentElement).appendChild(st);
                  return st;
                } catch { return null; }
              };
              const GM_log = function(...args) { console.log('[Prism Userscript]', ...args); };
              const GM = { info: GM_info, addStyle: (c) => Promise.resolve(GM_addStyle(c)) };
              try {
            \(item.code)
              } catch (err) {
                console.error('[Prism Userscript Error]', GM_info.script.name, err);
              }
            })();
            """
        }

        let initialStorage = UserscriptStorageStore.shared.getAll(profileId: profileId, scriptId: item.id)
        let storageData = (try? JSONSerialization.data(withJSONObject: initialStorage)) ?? Data("{}".utf8)
        let storageJson = String(data: storageData, encoding: .utf8) ?? "{}"
        let resourcesData = (try? JSONSerialization.data(withJSONObject: item.meta.resources)) ?? Data("{}".utf8)
        let resourcesJson = String(data: resourcesData, encoding: .utf8) ?? "{}"
        let scriptIdJson = (try? JSONSerialization.data(withJSONObject: [item.id])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let profileIdJson = (try? JSONSerialization.data(withJSONObject: [profileId])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"default\"]"

        return """
        (function() {
          'use strict';
          const __scriptId = \(scriptIdJson)[0];
          const __profileId = \(profileIdJson)[0];
          const __store = Object.assign(Object.create(null), \(storageJson));
          const __listeners = new Map();
          let __listenerSeq = 0;

          if (!window.__prismGmXhrCallbacks) {
            window.__prismGmXhrCallbacks = new Map();
            window.__prismGmXhrCallback = function(reqId, payload) {
              const cb = window.__prismGmXhrCallbacks.get(reqId);
              if (!cb) return;
              window.__prismGmXhrCallbacks.delete(reqId);
              cb(payload);
            };
          }

          const __post = (action, payload) => {
            try {
              window.webkit?.messageHandlers?.prismGmBridge?.postMessage(Object.assign({ action, scriptId: __scriptId, profileId: __profileId }, payload || {}));
            } catch {}
          };

          const __notifyListeners = (key, oldVal, newVal, remote) => {
            for (const entry of __listeners.values()) {
              if (entry.key === key) {
                try { entry.cb(key, oldVal, newVal, Boolean(remote)); } catch {}
              }
            }
          };

          const GM_info = \(infoJson);
          const unsafeWindow = window;

          const GM_getValue = (key, defaultValue) => Object.prototype.hasOwnProperty.call(__store, key) ? __store[key] : defaultValue;
          const GM_setValue = (key, value) => {
            const oldVal = GM_getValue(key, undefined);
            __store[key] = value;
            __notifyListeners(key, oldVal, value, false);
            __post('setValue', { key: String(key), value });
          };
          const GM_deleteValue = (key) => {
            if (Object.prototype.hasOwnProperty.call(__store, key)) {
              const oldVal = __store[key];
              delete __store[key];
              __notifyListeners(key, oldVal, undefined, false);
            }
            __post('deleteValue', { key: String(key) });
          };
          const GM_listValues = () => Object.keys(__store);
          const GM_addValueChangeListener = (key, cb) => {
            if (typeof cb !== 'function') return 0;
            const lid = ++__listenerSeq;
            __listeners.set(lid, { key: String(key), cb });
            return lid;
          };
          const GM_removeValueChangeListener = (lid) => { __listeners.delete(lid); };
          const GM_addStyle = function(css) {
            try {
              const text = String(css ?? '');
              if (typeof CSSStyleSheet === 'function' && 'adoptedStyleSheets' in document) {
                const sheet = new CSSStyleSheet();
                sheet.replaceSync(text);
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
                return sheet;
              }
              const st = document.createElement('style');
              st.textContent = text;
              (document.head || document.documentElement).appendChild(st);
              return st;
            } catch { return null; }
          };
          const GM_openInTab = (url, options) => {
            const activate = typeof options === 'boolean' ? !options : options?.active !== false;
            __post('openInTab', { url: String(url), activate });
            return { close: () => {}, closed: false };
          };
          const GM_setClipboard = (data) => { __post('setClipboard', { text: String(data ?? '') }); };
          const GM_notification = (textOrOpts, title) => {
            const text = typeof textOrOpts === 'string' ? textOrOpts : String(textOrOpts?.text || textOrOpts?.title || '');
            const t = typeof title === 'string' ? title : String(typeof textOrOpts === 'object' ? textOrOpts?.title || '' : '');
            __post('notify', { text, title: t });
          };
          const GM_getResourceText = (name) => {
            try {
              const map = \(resourcesJson);
              const val = map[name];
              return val && val.startsWith('text:') ? val.slice(5) : '';
            } catch { return ''; }
          };
          const GM_registerMenuCommand = () => 0;
          const GM_unregisterMenuCommand = () => {};
          const GM_log = (...args) => { console.log('[Prism Userscript]', ...args); };
          const GM_xmlhttpRequest = (details) => {
            if (!details || !details.url) {
              try { details && details.onerror && details.onerror({ status: 0, error: 'Invalid URL' }); } catch {}
              return { abort: () => {} };
            }
            let aborted = false;
            const reqId = 'xhr_' + Math.random().toString(36).slice(2) + Date.now();
            window.__prismGmXhrCallbacks.set(reqId, (res) => {
              if (aborted) return;
              if (!res || !res.ok) {
                try { details.onerror && details.onerror(res || { status: 0, error: 'Network error' }); } catch {}
                return;
              }
              let parsedResp = res.responseText || '';
              const rt = String(details.responseType || '').toLowerCase();
              if (rt === 'json') {
                try { parsedResp = JSON.parse(res.responseText || ''); } catch { parsedResp = null; }
              } else if (rt === 'arraybuffer' && res.base64Body) {
                try {
                  const bin = atob(res.base64Body);
                  const arr = new Uint8Array(bin.length);
                  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
                  parsedResp = arr.buffer;
                } catch {}
              } else if (rt === 'blob' && res.base64Body) {
                try {
                  const bin = atob(res.base64Body);
                  const arr = new Uint8Array(bin.length);
                  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
                  parsedResp = new Blob([arr]);
                } catch {}
              }
              const ev = {
                readyState: 4,
                status: res.status,
                statusText: res.statusText || 'OK',
                finalUrl: res.finalUrl || details.url,
                responseHeaders: res.responseHeaders || '',
                responseText: res.responseText || '',
                response: parsedResp,
                context: details.context,
              };
              try { details.onreadystatechange && details.onreadystatechange(ev); } catch {}
              try { details.onload && details.onload(ev); } catch {}
            });
            __post('xhr', {
              reqId,
              method: details.method || 'GET',
              url: String(details.url),
              headers: details.headers && typeof details.headers === 'object' ? details.headers : {},
              data: details.data !== undefined && details.data !== null ? String(details.data) : nil,
              timeout: typeof details.timeout === 'number' ? details.timeout : 15000,
              responseType: details.responseType || 'text',
              anonymous: Boolean(details.anonymous),
            });
            return { abort: () => { aborted = true; window.__prismGmXhrCallbacks.delete(reqId); } };
          };
          const GM = {
            info: GM_info,
            getValue: (k, d) => Promise.resolve(GM_getValue(k, d)),
            setValue: (k, v) => { GM_setValue(k, v); return Promise.resolve(); },
            deleteValue: (k) => { GM_deleteValue(k); return Promise.resolve(); },
            listValues: () => Promise.resolve(GM_listValues()),
            addStyle: (css) => Promise.resolve(GM_addStyle(css)),
            openInTab: (url, opts) => Promise.resolve(GM_openInTab(url, opts)),
            setClipboard: (data) => { GM_setClipboard(data); return Promise.resolve(); },
            notification: (a, b) => { GM_notification(a, b); return Promise.resolve(); },
            registerMenuCommand: (c, fn) => Promise.resolve(GM_registerMenuCommand(c, fn)),
            xmlHttpRequest: (details) => new Promise((resolve, reject) => {
              GM_xmlhttpRequest(Object.assign({}, details, {
                onload: (res) => { details.onload && details.onload(res); resolve(res); },
                onerror: (err) => { details.onerror && details.onerror(err); reject(err); },
              }));
            }),
          };
          try {
        \(item.code)
          } catch (err) {
            console.error('[Prism Userscript Error]', GM_info.script.name, err);
          }
        })();
        """
    }
}
