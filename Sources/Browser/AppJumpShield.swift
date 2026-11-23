import Foundation
import UIKit
import WebKit

@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

enum AppJumpDecision {
    case allowNormal
    case cancelSilently(incrementBlocked: Bool)
    case redirectInWebView(URL)
    case promptExternalApp(URL, appName: String)
    case promptSystemCommunication(URL)
}

enum AppJumpShield {
    private static let nativePassthroughSchemes: Set<String> = [
        "http", "https", "about", "blob", "data", "javascript", "file", "prism"
    ]

    private static let systemCommSchemes: Set<String> = [
        "tel", "mailto", "sms", "facetime", "facetime-audio"
    ]

    private static let appStoreHosts: Set<String> = [
        "apps.apple.com", "itunes.apple.com"
    ]

    private static let gatewayHosts: Set<String> = [
        "oia.zhihu.com",
        "oia.xiaohongshu.com",
        "ulp.taobao.com",
        "dl.hdslb.com",
        "zlink.toutiao.com",
        "lkme.cc",
        "mlinks.cc",
        "open.ulink.cc",
        "d.weibo.cn"
    ]

    private static let gatewayQueryKeys: [String] = [
        "target", "fallback_url", "redirect_url", "h5_url", "h5Url", "url", "dest", "next", "u", "to"
    ]

    static func isAppStoreHost(_ host: String) -> Bool {
        let low = host.lowercased()
        return appStoreHosts.contains(low) || appStoreHosts.contains(where: { low.hasSuffix(".\($0)") })
    }

    static func isGatewayHost(_ host: String) -> Bool {
        let low = host.lowercased()
        return gatewayHosts.contains(low) || gatewayHosts.contains(where: { low.hasSuffix(".\($0)") })
    }

    static func isGatewayURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else { return false }
        return isGatewayHost(host)
    }

    static func isBlockedSchemeOrAppStore(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        if nativePassthroughSchemes.contains(scheme) {
            if (scheme == "http" || scheme == "https"),
               let host = url.host,
               isAppStoreHost(host) {
                return true
            }
            return false
        }
        return true
    }

    static func evaluateNavigation(
        url: URL,
        currentTabURL: URL?,
        isMainFrame: Bool,
        withinGestureWindow: Bool,
        shieldEnabled: Bool,
        isAllowedOnce: Bool
    ) -> AppJumpDecision {
        guard shieldEnabled, !isAllowedOnce else {
            return .allowNormal
        }

        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .allowNormal
        }

        if systemCommSchemes.contains(scheme) {
            if isMainFrame && withinGestureWindow {
                return .promptSystemCommunication(url)
            }
            return .cancelSilently(incrementBlocked: false)
        }

        if scheme == "http" || scheme == "https" {
            let host = (url.host ?? "").lowercased()
            if !host.isEmpty && isAppStoreHost(host) {
                if isMainFrame && withinGestureWindow {
                    return .promptExternalApp(url, appName: friendlyAppName(for: url))
                }
                return .cancelSilently(incrementBlocked: true)
            }

            if !host.isEmpty && isGatewayHost(host) {
                if let cleanURL = unwrapGatewayURL(url, depth: 0),
                   !isSameWebPage(cleanURL, currentTabURL) {
                    return .redirectInWebView(cleanURL)
                }
                return .cancelSilently(incrementBlocked: true)
            }

            return .allowNormal
        }

        if nativePassthroughSchemes.contains(scheme) {
            return .allowNormal
        }

        // Non-whitelisted third-party custom scheme (tbopen://, fleamarket://, kwai://, xhsdiscover://, etc.)
        if isMainFrame && withinGestureWindow {
            return .promptExternalApp(url, appName: friendlyAppName(for: url))
        }
        return .cancelSilently(incrementBlocked: true)
    }

    static func unwrapGatewayURL(_ url: URL, depth: Int = 0) -> URL? {
        guard depth < 3, let host = url.host?.lowercased() else { return nil }

        // 1. Inspect query parameters first
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems, !items.isEmpty {
            for key in gatewayQueryKeys {
                if let rawVal = items.first(where: { $0.name == key })?.value,
                   let candidate = decodeHTTPURL(rawVal) {
                    let ch = (candidate.host ?? "").lowercased()
                    if isAppStoreHost(ch) { continue }
                    if isGatewayHost(ch) {
                        if let nested = unwrapGatewayURL(candidate, depth: depth + 1) {
                            return nested
                        }
                        continue
                    }
                    return candidate
                }
            }
        }

        // 2. Host-specific path mapping rules
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if host == "oia.zhihu.com" || host.hasSuffix(".oia.zhihu.com") {
            if segments.count >= 2 {
                let head = segments[0].lowercased()
                let objId = segments[1]
                switch head {
                case "questions", "question":
                    return URL(string: "https://www.zhihu.com/question/\(objId)")
                case "answers", "answer":
                    return URL(string: "https://www.zhihu.com/answer/\(objId)")
                case "p", "article", "articles":
                    return URL(string: "https://zhuanlan.zhihu.com/p/\(objId)")
                case "zvideos", "zvideo":
                    return URL(string: "https://www.zhihu.com/zvideo/\(objId)")
                default:
                    break
                }
            }
        } else if host == "oia.xiaohongshu.com" || host.hasSuffix(".oia.xiaohongshu.com") {
            if segments.count >= 3 && segments[0].lowercased() == "discovery" && segments[1].lowercased() == "item" {
                return URL(string: "https://www.xiaohongshu.com/explore/\(segments[2])")
            }
            if segments.count >= 2 && segments[0].lowercased() == "explore" {
                return URL(string: "https://www.xiaohongshu.com/explore/\(segments[1])")
            }
        } else if host == "d.weibo.cn" {
            if segments.count >= 2 && segments[0].lowercased() == "detail" {
                return URL(string: "https://m.weibo.cn/detail/\(segments[1])")
            }
            if let first = segments.first, first.count >= 8, first.allSatisfy(\.isNumber) {
                return URL(string: "https://m.weibo.cn/detail/\(first)")
            }
        }

        return nil
    }

    private static func decodeHTTPURL(_ raw: String) -> URL? {
        var cur = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 {
            if let u = URL(string: cur),
               let scheme = u.scheme?.lowercased(),
               scheme == "http" || scheme == "https",
               let host = u.host, !host.isEmpty {
                return u
            }
            guard let decoded = cur.removingPercentEncoding, decoded != cur else { break }
            cur = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func isSameWebPage(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        let normHost: (URL) -> String = { u in
            let h = (u.host ?? "").lowercased()
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        let normPath: (URL) -> String = { u in
            var p = u.path
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p.isEmpty ? "/" : p
        }
        let normQuery: (URL) -> String = { u in u.query ?? "" }
        return normHost(a) == normHost(b)
            && normPath(a) == normPath(b)
            && normQuery(a) == normQuery(b)
    }

    static func friendlyAppName(for url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()

        if isAppStoreHost(host) || scheme.hasPrefix("itms") {
            return "App Store"
        }
        if scheme == "zhihu" || host.contains("zhihu") {
            return L10n.t("知乎", "Zhihu")
        }
        if scheme == "xhsdiscover" || host.contains("xiaohongshu") {
            return L10n.t("小红书", "Xiaohongshu")
        }
        if scheme == "bilibili" || host.contains("bilibili") || host.contains("hdslb") {
            return L10n.t("哔哩哔哩", "Bilibili")
        }
        if scheme == "tbopen" || scheme == "taobao" || scheme == "tmall" || host.contains("taobao") || host.contains("tmall") {
            return L10n.t("淘宝", "Taobao")
        }
        if scheme == "fleamarket" || host.contains("goofish") {
            return L10n.t("闲鱼", "Idle Fish")
        }
        if scheme == "openapp.jdmobile" || scheme == "jdmobile" || host.contains("jd.com") {
            return L10n.t("京东", "JD")
        }
        if scheme == "pinduoduo" || scheme == "pddopen" {
            return L10n.t("拼多多", "Pinduoduo")
        }
        if scheme == "weixin" || scheme == "wechat" {
            return L10n.t("微信", "WeChat")
        }
        if scheme == "alipays" || scheme == "alipay" || scheme == "alipayqr" {
            return L10n.t("支付宝", "Alipay")
        }
        if scheme.hasPrefix("snssdk") || scheme == "aweme" || host.contains("toutiao") || host.contains("douyin") {
            return L10n.t("抖音 / 头条", "Douyin / Toutiao")
        }
        if scheme == "kwai" || scheme == "gifshow" {
            return L10n.t("快手", "Kuaishou")
        }
        if scheme == "weibo" || scheme == "sinaweibo" || host.contains("weibo") {
            return L10n.t("微博", "Weibo")
        }
        if scheme == "imeituan" || scheme == "meituan" {
            return L10n.t("美团", "Meituan")
        }
        if scheme == "dianping" {
            return L10n.t("大众点评", "Dianping")
        }
        if scheme == "dewu" || scheme == "poizon" {
            return L10n.t("得物", "Poizon")
        }
        if scheme == "baiduboxapp" || scheme == "com.baidu.tieba" || host.contains("baidu") {
            return L10n.t("百度 / 贴吧", "Baidu")
        }
        return scheme.isEmpty ? L10n.t("外部 App", "External App") : scheme.uppercased()
    }

    static func antiHijackScriptSource(enabled: Bool) -> String {
        let initialBool = enabled ? "true" : "false"
        return """
        window.__prismAppJumpShieldEnabled = \(initialBool);
        """ + coreAntiHijackJS
    }

    private static let coreAntiHijackJS = #"""
    (function() {
      if (window.__prismAppJumpShieldInstalled) {
        if (typeof window.__prismSetAppJumpShield === 'function') {
          window.__prismSetAppJumpShield(window.__prismAppJumpShieldEnabled);
        }
        return;
      }
      window.__prismAppJumpShieldInstalled = true;

      const ALLOWED_SCHEMES = new Set(['http:', 'https:', 'about:', 'blob:', 'data:', 'javascript:', 'file:', 'prism:']);
      const STORE_HOSTS = new Set(['apps.apple.com', 'itunes.apple.com']);
      const GATEWAY_HOSTS = new Set([
        'oia.zhihu.com',
        'oia.xiaohongshu.com',
        'ulp.taobao.com',
        'dl.hdslb.com',
        'zlink.toutiao.com',
        'lkme.cc',
        'mlinks.cc',
        'open.ulink.cc',
        'd.weibo.cn'
      ]);
      const QUERY_KEYS = ['target', 'fallback_url', 'redirect_url', 'h5_url', 'h5Url', 'url', 'dest', 'next', 'u', 'to'];

      let lastGestureAt = 0;
      let lastGestureTarget = null;
      let lastNativeGestureNotifyAt = 0;

      const recordGesture = (target) => {
        const now = Date.now();
        lastGestureAt = now;
        if (target) lastGestureTarget = target;
        if (now - lastNativeGestureNotifyAt >= 100) {
          lastNativeGestureNotifyAt = now;
          try {
            window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.prismBridge &&
              window.webkit.messageHandlers.prismBridge.postMessage({ type: 'userGesture', payload: {} });
          } catch (e) {}
        }
      };

      const hasRecentGesture = (windowMs) => (Date.now() - lastGestureAt) <= (windowMs || 850);

      ['pointerdown', 'touchstart', 'touchend', 'click'].forEach((evtName) => {
        window.addEventListener(evtName, (e) => {
          if (e && e.isTrusted !== false) {
            recordGesture(e.target);
          }
        }, { capture: true, passive: true });
      });

      const hostMatchesSet = (host, setObj) => {
        if (!host) return false;
        const h = host.toLowerCase();
        if (setObj.has(h)) return true;
        for (const base of setObj) {
          if (h.endsWith('.' + base)) return true;
        }
        return false;
      };

      const parseUrlSafe = (raw) => {
        if (!raw || typeof raw !== 'string') return null;
        const s = raw.trim();
        if (!s) return null;
        try { return new URL(s, location.href); } catch (e) { return null; }
      };

      const isBlockedSchemeOrStore = (raw) => {
        const u = parseUrlSafe(raw);
        if (!u) {
          const m = typeof raw === 'string' && raw.trim().match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)/);
          if (m && !ALLOWED_SCHEMES.has(m[1].toLowerCase())) return true;
          return false;
        }
        const proto = (u.protocol || '').toLowerCase();
        if (!ALLOWED_SCHEMES.has(proto)) return true;
        if ((proto === 'http:' || proto === 'https:') && hostMatchesSet(u.hostname, STORE_HOSTS)) return true;
        return false;
      };

      const isGateway = (raw) => {
        const u = parseUrlSafe(raw);
        if (!u) return false;
        const proto = (u.protocol || '').toLowerCase();
        return (proto === 'http:' || proto === 'https:') && hostMatchesSet(u.hostname, GATEWAY_HOSTS);
      };

      const tryUnwrapGateway = (raw) => {
        const u = parseUrlSafe(raw);
        if (!u) return null;
        for (const key of QUERY_KEYS) {
          const val = u.searchParams.get(key);
          if (!val) continue;
          let candidate = val.trim();
          for (let pass = 0; pass < 2; pass++) {
            const parsed = parseUrlSafe(candidate);
            if (parsed && (parsed.protocol === 'http:' || parsed.protocol === 'https:') &&
                !hostMatchesSet(parsed.hostname, STORE_HOSTS) &&
                !hostMatchesSet(parsed.hostname, GATEWAY_HOSTS)) {
              return parsed.href;
            }
            try {
              const dec = decodeURIComponent(candidate);
              if (dec === candidate) break;
              candidate = dec;
            } catch (e) { break; }
          }
        }
        return null;
      };

      const isBlockedOrGateway = (raw) => isBlockedSchemeOrStore(raw) || isGateway(raw);

      // Layer 3A: Block rogue hidden iframes & programmatic scheme hijacks
      try {
        const origSetAttr = HTMLIFrameElement.prototype.setAttribute;
        HTMLIFrameElement.prototype.setAttribute = function(name, value) {
          if (window.__prismAppJumpShieldEnabled && typeof name === 'string' && name.toLowerCase() === 'src') {
            if (isBlockedOrGateway(String(value || ''))) {
              return;
            }
          }
          return origSetAttr.apply(this, arguments);
        };

        const srcDesc = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src');
        if (srcDesc && srcDesc.set) {
          Object.defineProperty(HTMLIFrameElement.prototype, 'src', {
            configurable: true,
            enumerable: srcDesc.enumerable,
            get: srcDesc.get,
            set: function(value) {
              if (window.__prismAppJumpShieldEnabled && isBlockedOrGateway(String(value || ''))) {
                return;
              }
              return srcDesc.set.call(this, value);
            }
          });
        }
      } catch (e) {}

      try {
        const origOpen = window.open;
        window.open = function(url, target, features) {
          if (window.__prismAppJumpShieldEnabled && typeof url === 'string' && url.trim()) {
            if (isGateway(url)) {
              const clean = tryUnwrapGateway(url);
              if (clean && hasRecentGesture(850)) {
                return origOpen.call(this, clean, target, features);
              }
              return null;
            }
            if (isBlockedSchemeOrStore(url) || !hasRecentGesture(850)) {
              return null;
            }
          }
          return origOpen.apply(this, arguments);
        };
      } catch (e) {}

      // Layer 3B: Anti-Clipboard Hijack (Block stealth token / red-packet poisoning)
      const isExplicitCopyControl = (startEl) => {
        let el = startEl;
        for (let depth = 0; el && depth < 4; depth += 1) {
          const tag = (el.tagName || '').toLowerCase();
          if (tag === 'body' || tag === 'html') break;
          const cls = typeof el.className === 'string' ? el.className : '';
          const meta = [
            cls,
            el.id || '',
            el.getAttribute ? (el.getAttribute('aria-label') || '') : '',
            el.getAttribute ? (el.getAttribute('title') || '') : ''
          ].join(' ');
          const shortText = ((el.innerText || el.textContent || '') + '').trim().slice(0, 28);
          const hasPositive = /(copy|clipboard|拷贝|复制|一键复制|share|分享)/i.test(meta + ' ' + shortText);
          const hasClipboardAttr = Boolean(el.getAttribute && (el.getAttribute('data-clipboard-text') !== null || el.getAttribute('data-clipboard-target') !== null));
          const looksLikeExpandTrap = /(展开|查看全文|阅读全文|打开|下载|app)/i.test(shortText) && !/(复制|copy|拷贝)/i.test(shortText);
          if ((hasPositive || hasClipboardAttr) && !looksLikeExpandTrap) {
            return true;
          }
          el = el.parentElement;
        }
        return false;
      };

      const isStealthOffscreenActiveElement = () => {
        const ae = document.activeElement;
        if (!ae || (ae.tagName !== 'TEXTAREA' && ae.tagName !== 'INPUT')) return false;
        try {
          const st = getComputedStyle(ae);
          const r = ae.getBoundingClientRect();
          if (st.opacity === '0' || st.fontSize === '0px' || r.width <= 2 || r.height <= 2 || r.right < -50 || r.left < -100) {
            return true;
          }
        } catch (e) {}
        return false;
      };

      const canSafelyWriteClipboard = () => {
        if (!window.__prismAppJumpShieldEnabled) return true;
        if (hasRecentGesture(1500) && isExplicitCopyControl(lastGestureTarget)) {
          return true;
        }
        try {
          const sel = window.getSelection ? window.getSelection() : null;
          const selText = sel ? String(sel).trim() : '';
          if (selText.length > 0 && !isStealthOffscreenActiveElement()) {
            return true;
          }
        } catch (e) {}
        return false;
      };

      try {
        if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
          const origWriteText = navigator.clipboard.writeText.bind(navigator.clipboard);
          navigator.clipboard.writeText = function(text) {
            if (!canSafelyWriteClipboard()) {
              return Promise.resolve();
            }
            return origWriteText(text);
          };
        }
      } catch (e) {}

      try {
        const origExecCommand = document.execCommand;
        if (typeof origExecCommand === 'function') {
          document.execCommand = function(commandId) {
            if (typeof commandId === 'string' && commandId.toLowerCase() === 'copy') {
              if (!canSafelyWriteClipboard()) {
                return true;
              }
            }
            return origExecCommand.apply(this, arguments);
          };
        }
      } catch (e) {}

      // Layer 4: Domestic Site Unfolder & Clutter Hider (Host-Gated)
      const getUnfolderRuleSet = () => {
        const h = (location.hostname || '').toLowerCase();
        if (!h) return null;
        if (h === 'zhihu.com' || h.endsWith('.zhihu.com')) {
          return {
            css: [
              '.RichContent-inner, .QuestionAnswer-content, .Post-RichTextContainer { max-height: none !important; height: auto !important; overflow: visible !important; }',
              '.ContentItem-expandButton, .MobileAppHeader-downloadLink, .OpenInAppButton, .OpenInApp, .DownloadGuide, .AppHeader-download { display: none !important; }',
              '.ModalWrap:has(.OpenInAppButton), .ModalWrap:has(.OpenInApp) { display: none !important; }'
            ].join('\n'),
            expandSelectors: '.RichContent-inner, .QuestionAnswer-content, .Post-RichTextContainer'
          };
        }
        if (h === 'xiaohongshu.com' || h.endsWith('.xiaohongshu.com')) {
          return {
            css: [
              '.note-content, .desc, .note-scroller { max-height: none !important; height: auto !important; overflow: visible !important; }',
              '.launch-app-btn, .open-app-btn, .open-app-banner, .bottom-banner, .note-open-app, .reds-modal-open-app { display: none !important; }'
            ].join('\n'),
            expandSelectors: '.note-content, .desc, .note-scroller'
          };
        }
        if (h === 'm.bilibili.com') {
          return {
            css: '.m-nav-openapp, .launch-app-btn, .open-app-bar, .player-mobile-openapp, .fixed-openapp, .m-video-openapp, .openapp-dialog { display: none !important; }',
            expandSelectors: ''
          };
        }
        if (h === 'm.weibo.cn' || h === 'weibo.com' || h.endsWith('.weibo.com')) {
          return {
            css: [
              '.weibo-text, .weibo-og, .card-wrap { max-height: none !important; height: auto !important; overflow: visible !important; }',
              '.wrap-open-app, .lite-page-top, .open-app, .btn-open-app { display: none !important; }'
            ].join('\n'),
            expandSelectors: '.weibo-text, .weibo-og, .card-wrap'
          };
        }
        if (h === 'baijiahao.baidu.com' || h === 'mbd.baidu.com' || h === 'tieba.baidu.com' || h.endsWith('.tieba.baidu.com')) {
          return {
            css: [
              '#mainContentContainer, .mainContent, .content, .p_content, .pb_list_pager { max-height: none !important; height: auto !important; overflow: visible !important; -webkit-line-clamp: unset !important; }',
              '.packupArrow, .openApp, .app-guide, .tb-banner, .bottom-open-app, .call-app-btn, .j_open_app, .head-open-app { display: none !important; }'
            ].join('\n'),
            expandSelectors: '#mainContentContainer, .mainContent, .content, .p_content'
          };
        }
        if (h === 'csdn.net' || h.endsWith('.csdn.net')) {
          return {
            css: [
              '#content_views, #article_content, .article_content, .htmledit_views, .blog-content-box { max-height: none !important; height: auto !important; overflow: visible !important; }',
              '.hide-article-box, .btn-readmore, .open-app, .weixin-shadowbox, #passportbox, .feed-Sign-span, .readall_box { display: none !important; }'
            ].join('\n'),
            expandSelectors: '#content_views, #article_content, .article_content'
          };
        }
        if (h === 'jianshu.com' || h.endsWith('.jianshu.com')) {
          return {
            css: [
              '.show-content-free, #note-show-content, .collapse-free-content { max-height: none !important; height: auto !important; overflow: visible !important; }',
              '.open-app-btn, .download-app-guidance, .note-graceful-button, .collapse-tips, .call-app-btn { display: none !important; }'
            ].join('\n'),
            expandSelectors: '.show-content-free, #note-show-content, .collapse-free-content'
          };
        }
        return null;
      };

      const ruleSet = (window === window.top) ? getUnfolderRuleSet() : null;
      const STYLE_ID = '__prism_unfolder_css';

      const applyUnfolderStyle = () => {
        if (!ruleSet) return;
        const existing = document.getElementById(STYLE_ID);
        if (!window.__prismAppJumpShieldEnabled) {
          if (existing) existing.remove();
          return;
        }
        if (existing) return;
        const style = document.createElement('style');
        style.id = STYLE_ID;
        style.textContent = ruleSet.css;
        (document.head || document.documentElement).appendChild(style);
      };

      window.__prismSetAppJumpShield = function(enabled) {
        window.__prismAppJumpShieldEnabled = Boolean(enabled);
        applyUnfolderStyle();
      };

      if (ruleSet) {
        if (document.head || document.documentElement) applyUnfolderStyle();
        else document.addEventListener('DOMContentLoaded', applyUnfolderStyle, { once: true });
        document.addEventListener('DOMContentLoaded', applyUnfolderStyle, { once: true });

        document.addEventListener('click', (e) => {
          if (!window.__prismAppJumpShieldEnabled) return;
          const btn = e.target && e.target.closest && e.target.closest('a, button, [role="button"], .ContentItem-expandButton, .btn-readmore, .packupArrow, .open-app, .OpenInAppButton');
          if (!btn) return;
          const label = ((btn.innerText || btn.textContent || '') + ' ' + (btn.className || '')).trim();
          const isExpandOrOpen = /(展开|全文|查看更多|open.*app|app内打开|OpenInApp)/i.test(label);
          const href = btn.getAttribute ? (btn.getAttribute('href') || '') : '';
          if (isExpandOrOpen || (href && isBlockedOrGateway(href))) {
            if (ruleSet.expandSelectors) {
              document.querySelectorAll(ruleSet.expandSelectors).forEach((el) => {
                el.style.maxHeight = 'none';
                el.style.height = 'auto';
                el.style.overflow = 'visible';
              });
            }
            if (href && isBlockedOrGateway(href)) {
              e.preventDefault();
              e.stopImmediatePropagation();
            }
          }
        }, true);
      }
    })();
    """#
}
