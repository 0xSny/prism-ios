import Foundation
import LocalAuthentication
import UIKit
import WebKit

@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id: UUID
    @Published var profileId: String
    @Published var title: String = "新标签页"
    @Published var urlString: String = ""
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isNewTab: Bool = true
    @Published var blockedCount: Int = 0
    @Published var isTranslated: Bool = false
    @Published var hasVideo: Bool = false
    @Published var videoSeconds: Double = 0
    @Published var videoDuration: Double = 0
    @Published var videoPaused: Bool = true
    @Published var playbackRate: Double = 1.0
    @Published var sniffedMedia: [SniffedMediaItem] = []
    @Published var consoleLogs: [ConsoleLogEntry] = []
    @Published var networkLogs: [NetworkLogEntry] = []
    @Published var matchedPasswords: [PasswordEntry] = []
    @Published var showAutofillBar: Bool = false
    @Published var pendingPasswordSave: (origin: String, username: String, password: String)?
    @Published var blockedAppJumpURL: URL?

    var webView: WKWebView?

    init(id: UUID = UUID(), profileId: String, initialURL: URL? = nil) {
        self.id = id
        self.profileId = profileId
        if let url = initialURL {
            self.isNewTab = false
            self.urlString = url.absoluteString
            self.title = url.host ?? url.absoluteString
        } else {
            self.title = L10n.t("新标签页", "New Tab")
        }
    }
}

@MainActor
final class TabManager: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID?
    @Published var activeToast: ToastNotice?
    @Published var searchEngine: SearchEngineOption = .google
    @Published var appTheme: AppTheme = .system
    @Published var adblockEnabled: Bool = true
    @Published var blockRogueAppJumps: Bool = true
    @Published var desktopMode: Bool = false

    weak var syncEngine: SyncEngine?
    weak var handoffService: HandoffService?

    private var lastClipboardChangeCount: Int = UIPasteboard.general.changeCount
    private var lastPromptedClipboard: String = ""
    private var allowedOnceJumpURL: URL?

    override init() {
        super.init()
        if let rawEngine = UserDefaults.standard.string(forKey: "prism.searchEngine"),
           let eng = SearchEngineOption(rawValue: rawEngine) {
            self.searchEngine = eng
        }
        if let rawTheme = UserDefaults.standard.string(forKey: "prism.theme"),
           let theme = AppTheme(rawValue: rawTheme) {
            self.appTheme = theme
        }
        BackgroundMediaController.shared.configureAudioSession()
        createTab(url: nil, activate: true)
    }

    var activeTab: BrowserTab? {
        tabs.first(where: { $0.id == activeTabId }) ?? tabs.first
    }

    var activeProfile: BrowserProfile {
        let profiles = syncEngine?.profiles ?? [.defaultProfile]
        let pid = activeTab?.profileId ?? "default"
        return profiles.first(where: { $0.id == pid }) ?? profiles.first ?? .defaultProfile
    }

    @discardableResult
    func createTab(url: URL? = nil, profileId: String? = nil, activate: Bool = true) -> BrowserTab {
        let pid = profileId ?? activeProfile.id
        let tab = BrowserTab(profileId: pid, initialURL: url)
        tabs.append(tab)
        if activate {
            activeTabId = tab.id
        }
        if let url {
            load(url: url, in: tab)
        }
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].webView?.stopLoading()
        tabs.remove(at: idx)
        if tabs.isEmpty {
            createTab(url: nil, activate: true)
            return
        }
        if activeTabId == id {
            let nextIdx = min(idx, tabs.count - 1)
            activeTabId = tabs[nextIdx].id
        }
    }

    func switchTab(byOffset offset: Int) {
        guard tabs.count > 1, let curId = activeTabId,
              let curIdx = tabs.firstIndex(where: { $0.id == curId }) else { return }
        let nextIdx = (curIdx + offset + tabs.count) % tabs.count
        activeTabId = tabs[nextIdx].id
    }

    func navigateActive(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tab = activeTab else { return }

        if let url = resolveUserInputToURL(trimmed) {
            load(url: url, in: tab)
        }
    }

    func load(url: URL, in tab: BrowserTab, seekSeconds: Double? = nil) {
        let webView = ensureWebView(for: tab)
        tab.isNewTab = false
        tab.urlString = url.absoluteString
        tab.isTranslated = false
        tab.matchedPasswords = []
        tab.showAutofillBar = false
        tab.blockedAppJumpURL = nil
        webView.load(URLRequest(url: url))

        if let seekSeconds, seekSeconds > 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                webView.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('seekTo', \(seekSeconds));", completionHandler: nil)
            }
        }
    }

    func ensureWebView(for tab: BrowserTab) -> WKWebView {
        if let existing = tab.webView {
            return existing
        }
        let profile = (syncEngine?.profiles ?? [.defaultProfile]).first(where: { $0.id == tab.profileId }) ?? .defaultProfile
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ProfileDataStoreRegistry.shared.dataStore(for: profile)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true

        let ucc = config.userContentController
        ucc.add(self, name: "prismBridge")
        ucc.addUserScript(WKUserScript(source: MediaSnifferScripts.injectScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let fpScript = ProfileDataStoreRegistry.shared.fingerprintUserScript(for: profile) {
            ucc.addUserScript(fpScript)
        }
        AdBlockManager.shared.apply(to: ucc, enabled: adblockEnabled && profile.fingerprint.blockTrackers)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if desktopMode {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        } else if let customUA = profile.fingerprint.userAgent, !customUA.isEmpty {
            webView.customUserAgent = customUA
        }
        tab.webView = webView
        return webView
    }

    func switchProfileForActiveTab(_ profileId: String) {
        guard let tab = activeTab else { return }
        let currentUrl = URL(string: tab.urlString)
        tab.webView?.stopLoading()
        tab.webView = nil
        tab.profileId = profileId
        if !tab.isNewTab, let currentUrl {
            load(url: currentUrl, in: tab)
        }
    }

    func toggleDesktopUserAgent() {
        desktopMode.toggle()
        guard let tab = activeTab, let webView = tab.webView else { return }
        if desktopMode {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        } else {
            let ua = activeProfile.fingerprint.userAgent
            webView.customUserAgent = (ua?.isEmpty == false) ? ua : nil
        }
        webView.reload()
    }

    func togglePageTranslation() {
        guard let tab = activeTab, let webView = tab.webView else { return }
        if tab.isTranslated {
            webView.evaluateJavaScript(TranslatorService.toggleOriginalJS()) { _, _ in
                Task { @MainActor in tab.isTranslated = false }
            }
            return
        }
        webView.evaluateJavaScript(TranslatorService.collectNodesJS) { result, _ in
            guard let dict = result as? [String: Any] else { return }
            if (dict["toggleOn"] as? Bool) == true {
                Task { @MainActor in tab.isTranslated = true }
                return
            }
            guard let texts = dict["texts"] as? [String], !texts.isEmpty else { return }
            Task {
                let translated = await TranslatorService.translateBatch(texts)
                let applyJS = TranslatorService.applyTranslationsJS(translated)
                await MainActor.run {
                    webView.evaluateJavaScript(applyJS) { _, _ in
                        tab.isTranslated = true
                    }
                }
            }
        }
    }

    func toggleBookmarkCurrentPage() {
        guard let tab = activeTab, !tab.isNewTab, !tab.urlString.isEmpty, let syncEngine else { return }
        if let idx = syncEngine.bookmarks.firstIndex(where: { $0.url == tab.urlString }) {
            syncEngine.bookmarks.remove(at: idx)
            showToast(L10n.t("已移除书签", "Bookmark removed"))
        } else {
            let item = BookmarkItem(
                id: UUID().uuidString,
                type: "url",
                parentId: nil,
                order: syncEngine.bookmarks.count,
                title: tab.title.isEmpty ? tab.urlString : tab.title,
                url: tab.urlString,
                favicon: nil,
                profileId: tab.profileId,
                createdAt: Date().timeIntervalSince1970 * 1000,
                updatedAt: Date().timeIntervalSince1970 * 1000
            )
            syncEngine.bookmarks.append(item)
            showToast(L10n.t("已收藏并同步到云端", "Bookmarked & syncing"))
        }
        syncEngine.notifyScopeDirty("bookmarks")
    }

    func isCurrentBookmarked() -> Bool {
        guard let tab = activeTab, !tab.urlString.isEmpty, let syncEngine else { return false }
        return syncEngine.bookmarks.contains(where: { $0.url == tab.urlString })
    }

    func allowOnceAppJump(_ url: URL) {
        allowedOnceJumpURL = url
        activeTab?.blockedAppJumpURL = nil
        UIApplication.shared.open(url)
    }

    func autofillWithFaceID(entry: PasswordEntry) {
        let context = LAContext()
        var err: NSError?
        let reason = L10n.t("验证面容 ID 以自动填充账号密码", "Authenticate to autofill credentials")
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] ok, _ in
                guard ok else { return }
                Task { @MainActor in
                    guard let webView = self?.activeTab?.webView else { return }
                    webView.evaluateJavaScript(MediaSnifferScripts.autofillJS(username: entry.username, password: entry.password), completionHandler: nil)
                    self?.activeTab?.showAutofillBar = false
                }
            }
        }
    }

    func savePendingPassword() {
        guard let tab = activeTab, let pending = tab.pendingPasswordSave, let syncEngine else { return }
        let now = Date().timeIntervalSince1970 * 1000
        if let idx = syncEngine.passwords.firstIndex(where: { $0.origin == pending.origin && $0.username == pending.username }) {
            syncEngine.passwords[idx].password = pending.password
            syncEngine.passwords[idx].updatedAt = now
        } else {
            syncEngine.passwords.insert(
                PasswordEntry(
                    id: UUID().uuidString,
                    origin: pending.origin,
                    username: pending.username,
                    password: pending.password,
                    note: nil,
                    createdAt: now,
                    updatedAt: now
                ),
                at: 0
            )
        }
        tab.pendingPasswordSave = nil
        syncEngine.notifyScopeDirty("passwords")
        showToast(L10n.t("已加密保存并同步密码", "Password saved & encrypted"))
    }

    func checkClipboardForURL() {
        let board = UIPasteboard.general
        guard board.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = board.changeCount
        guard let text = board.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text != lastPromptedClipboard,
              text != activeTab?.urlString,
              let url = extractHTTPURL(from: text) else { return }
        lastPromptedClipboard = text
        activeToast = ToastNotice(
            message: L10n.t("检测到剪贴板链接：", "Clipboard URL detected: ") + (url.host ?? url.absoluteString),
            actionTitle: L10n.t("立即打开", "Open"),
            urlToOpen: url.absoluteString,
            handoff: nil
        )
        let toastId = activeToast?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.activeToast?.id == toastId {
                self?.activeToast = nil
            }
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "prism" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host == "open",
           let rawTarget = comps?.queryItems?.first(where: { $0.name == "url" })?.value,
           let targetUrl = URL(string: rawTarget) {
            createTab(url: targetUrl, activate: true)
        }
    }

    func showToast(_ message: String, actionTitle: String? = nil, urlToOpen: String? = nil, handoff: HandoffPayload? = nil) {
        let notice = ToastNotice(message: message, actionTitle: actionTitle, urlToOpen: urlToOpen, handoff: handoff)
        activeToast = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            if self?.activeToast?.id == notice.id {
                self?.activeToast = nil
            }
        }
    }

    // MARK: - WKNavigationDelegate & WKUIDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if blockRogueAppJumps, let allowed = allowedOnceJumpURL, allowed == url {
            allowedOnceJumpURL = nil
            decisionHandler(.allow)
            return
        }
        if blockRogueAppJumps && AdBlockManager.shouldInterceptNavigation(url) {
            if let tab = tabs.first(where: { $0.webView === webView }) {
                tab.blockedCount += 1
                tab.blockedAppJumpURL = url
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if navigationAction.targetFrame == nil {
                createTab(url: url, profileId: tabs.first(where: { $0.webView === webView })?.profileId, activate: true)
            } else {
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        syncWebViewState(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncWebViewState(webView)
        guard let tab = tabs.first(where: { $0.webView === webView }),
              let urlStr = webView.url?.absoluteString,
              !urlStr.isEmpty else { return }
        if let syncEngine {
            let item = HistoryItem(
                id: UUID().uuidString,
                url: urlStr,
                title: webView.title ?? urlStr,
                profileId: tab.profileId,
                visitedAt: Date().timeIntervalSince1970 * 1000
            )
            syncEngine.history.removeAll(where: { $0.url == urlStr })
            syncEngine.history.insert(item, at: 0)
            if syncEngine.history.count > 500 {
                syncEngine.history = Array(syncEngine.history.prefix(500))
            }
            syncEngine.notifyScopeDirty("history")
        }
    }

    func syncWebViewState(_ webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        tab.title = webView.title?.isEmpty == false ? (webView.title ?? tab.urlString) : (webView.url?.host ?? L10n.t("加载中...", "Loading..."))
        tab.urlString = webView.url?.absoluteString ?? tab.urlString
        tab.isLoading = webView.isLoading
        tab.estimatedProgress = webView.estimatedProgress
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "prismBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let payload = body["payload"] as? [String: Any] else { return }
        let webView = message.webView
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }

        switch type {
        case "media":
            guard let url = payload["url"] as? String,
                  let ext = payload["ext"] as? String else { return }
            let title = (payload["title"] as? String) ?? tab.title
            if !tab.sniffedMedia.contains(where: { $0.url == url }) {
                tab.sniffedMedia.insert(SniffedMediaItem(url: url, mediaExt: ext, title: title, pageUrl: tab.urlString), at: 0)
            }
        case "console":
            let level = (payload["level"] as? String) ?? "log"
            let msg = (payload["message"] as? String) ?? ""
            tab.consoleLogs.append(ConsoleLogEntry(level: level, message: msg))
            if tab.consoleLogs.count > 200 { tab.consoleLogs.removeFirst() }
        case "network":
            let method = (payload["method"] as? String) ?? "GET"
            let url = (payload["url"] as? String) ?? ""
            let status = (payload["status"] as? Int) ?? 0
            let duration = (payload["durationMs"] as? Int) ?? 0
            tab.networkLogs.insert(NetworkLogEntry(method: method, url: url, status: status, durationMs: duration), at: 0)
            if tab.networkLogs.count > 200 { tab.networkLogs.removeLast() }
        case "videoState":
            tab.hasVideo = (payload["hasVideo"] as? Bool) ?? false
            tab.videoPaused = (payload["paused"] as? Bool) ?? true
            tab.videoSeconds = (payload["currentTime"] as? Double) ?? 0
            tab.videoDuration = (payload["duration"] as? Double) ?? 0
            tab.playbackRate = (payload["rate"] as? Double) ?? 1.0
            let host = URL(string: tab.urlString)?.host ?? "Prism"
            BackgroundMediaController.shared.updateNowPlaying(
                title: tab.title,
                host: host,
                duration: tab.videoDuration,
                elapsed: tab.videoSeconds,
                playing: !tab.videoPaused
            )
        case "passwordFocus":
            guard let origin = payload["origin"] as? String, let syncEngine else { return }
            let host = URL(string: origin)?.host ?? origin
            let matches = syncEngine.passwords.filter { $0.origin.contains(host) || origin.contains($0.origin) }
            tab.matchedPasswords = matches
            tab.showAutofillBar = !matches.isEmpty
        case "passwordCapture":
            guard let origin = payload["origin"] as? String,
                  let password = payload["password"] as? String,
                  !password.isEmpty else { return }
            let username = (payload["username"] as? String) ?? ""
            tab.pendingPasswordSave = (origin: origin, username: username, password: password)
        default:
            break
        }
    }

    // MARK: - URL Parsing

    private func resolveUserInputToURL(_ raw: String) -> URL? {
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return URL(string: raw)
        }
        if !raw.contains(" "), raw.contains("."), !raw.hasPrefix(".") {
            return URL(string: "https://\(raw)")
        }
        return searchEngine.searchURL(for: raw)
    }

    private func extractHTTPURL(from text: String) -> URL? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: text.utf16.count)
            if let match = detector.firstMatch(in: text, options: [], range: range),
               let url = match.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }
}
