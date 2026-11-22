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
    private static let darkWebBackdropColor = UIColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1.0)

    @Published var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID?
    @Published var activeToast: ToastNotice?
    @Published var searchEngine: SearchEngineOption = .google
    @Published var appTheme: AppTheme = .system {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "prism.theme")
            applyWebDarkModeToAllTabs()
        }
    }
    @Published var webDarkModeFollowTheme: Bool = true {
        didSet {
            UserDefaults.standard.set(webDarkModeFollowTheme, forKey: "prism.webDarkModeFollowTheme")
            applyWebDarkModeToAllTabs()
        }
    }
    @Published var webDarkModeWhitelistHosts: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(webDarkModeWhitelistHosts).sorted(), forKey: "prism.webDarkModeWhitelistHosts")
            applyWebDarkModeToAllTabs()
        }
    }
    @Published var adblockEnabled: Bool = true
    @Published var blockRogueAppJumps: Bool = true
    @Published var desktopMode: Bool = false

    weak var syncEngine: SyncEngine?
    weak var handoffService: HandoffService?

    private var lastClipboardChangeCount: Int = UIPasteboard.general.changeCount
    private var lastPromptedClipboard: String = ""
    private var allowedOnceJumpURL: URL?
    private var systemIsDark: Bool = UITraitCollection.current.userInterfaceStyle == .dark

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
        if UserDefaults.standard.object(forKey: "prism.webDarkModeFollowTheme") != nil {
            self.webDarkModeFollowTheme = UserDefaults.standard.bool(forKey: "prism.webDarkModeFollowTheme")
        }
        if let savedHosts = UserDefaults.standard.stringArray(forKey: "prism.webDarkModeWhitelistHosts") {
            let cleaned = savedHosts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            self.webDarkModeWhitelistHosts = Set(cleaned)
        }
        BackgroundMediaController.shared.configureAudioSession()
        createTab(url: nil, activate: true)
    }

    var isEffectiveAppDark: Bool {
        switch appTheme {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            return systemIsDark
        }
    }

    func updateSystemDark(_ isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        applyWebDarkModeToAllTabs()
    }

    func normalizedHTTPHost(from url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    var activeTabHTTPHost: String? {
        guard let tab = activeTab, !tab.isNewTab else { return nil }
        return normalizedHTTPHost(from: URL(string: tab.urlString))
    }

    var isActiveTabWebDarkWhitelisted: Bool {
        guard let host = activeTabHTTPHost else { return false }
        return webDarkModeWhitelistHosts.contains(host)
    }

    func effectiveWebDarkEnabled(for url: URL?) -> Bool {
        guard isEffectiveAppDark && webDarkModeFollowTheme else { return false }
        if let host = normalizedHTTPHost(from: url), webDarkModeWhitelistHosts.contains(host) {
            return false
        }
        return true
    }

    func toggleWebDarkWhitelistForActiveTab() {
        guard let host = activeTabHTTPHost else { return }
        if webDarkModeWhitelistHosts.contains(host) {
            webDarkModeWhitelistHosts.remove(host)
            showToast(L10n.t("已恢复此网站网页深色", "Web dark mode restored for this site"))
        } else {
            webDarkModeWhitelistHosts.insert(host)
            showToast(L10n.t("已在此网站关闭网页深色", "Web dark mode disabled for this site"))
        }
    }

    func clearWebDarkWhitelist() {
        webDarkModeWhitelistHosts.removeAll()
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
    func createTab(url: URL? = nil, profileId: String? = nil, activate: Bool = true, seekSeconds: Double? = nil) -> BrowserTab {
        let pid = profileId ?? activeProfile.id
        let tab = BrowserTab(profileId: pid, initialURL: url)
        tabs.append(tab)
        if activate {
            activeTabId = tab.id
        }
        if let url {
            load(url: url, in: tab, seekSeconds: seekSeconds)
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

        if let seekSeconds, seekSeconds > 0 {
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
        configureUserScripts(on: ucc, profile: profile, initialURL: URL(string: tab.urlString))
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
        applyWebDarkAppearance(to: webView, url: URL(string: tab.urlString))
        tab.webView = webView
        return webView
    }

    private func configureUserScripts(on ucc: WKUserContentController, profile: BrowserProfile, initialURL: URL?) {
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: MediaSnifferScripts.injectScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let fpScript = ProfileDataStoreRegistry.shared.fingerprintUserScript(for: profile) {
            ucc.addUserScript(fpScript)
        }
        let followThemeDark = isEffectiveAppDark && webDarkModeFollowTheme
        let initialEnabled = effectiveWebDarkEnabled(for: initialURL)
        let startScript = WebDarkModeScripts.documentStartSource(
            initialEnabled: initialEnabled,
            followThemeDark: followThemeDark,
            whitelistHosts: webDarkModeWhitelistHosts
        )
        let endScript = WebDarkModeScripts.documentEndSource()
        ucc.addUserScript(WKUserScript(source: startScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: endScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func applyWebDarkAppearance(to webView: WKWebView, url: URL? = nil) {
        let targetURL = url ?? webView.url
        let enabled = effectiveWebDarkEnabled(for: targetURL)
        if enabled {
            if webView.overrideUserInterfaceStyle != .dark {
                webView.overrideUserInterfaceStyle = .dark
            }
            if webView.isOpaque {
                webView.isOpaque = false
            }
            if webView.backgroundColor != Self.darkWebBackdropColor {
                webView.backgroundColor = Self.darkWebBackdropColor
            }
            if webView.scrollView.backgroundColor != Self.darkWebBackdropColor {
                webView.scrollView.backgroundColor = Self.darkWebBackdropColor
            }
            if #available(iOS 15.0, *), webView.underPageBackgroundColor != Self.darkWebBackdropColor {
                webView.underPageBackgroundColor = Self.darkWebBackdropColor
            }
        } else {
            let isWhitelisted: Bool = {
                guard let host = normalizedHTTPHost(from: targetURL) else { return false }
                return webDarkModeWhitelistHosts.contains(host)
            }()
            let targetStyle: UIUserInterfaceStyle =
                (isEffectiveAppDark && (!webDarkModeFollowTheme || isWhitelisted))
                    ? .light
                    : (appTheme == .system ? .unspecified : .light)
            if webView.overrideUserInterfaceStyle != targetStyle {
                webView.overrideUserInterfaceStyle = targetStyle
            }
            if !webView.isOpaque {
                webView.isOpaque = true
            }
            if webView.backgroundColor != .systemBackground {
                webView.backgroundColor = .systemBackground
            }
            if webView.scrollView.backgroundColor != .systemBackground {
                webView.scrollView.backgroundColor = .systemBackground
            }
            if #available(iOS 15.0, *), webView.underPageBackgroundColor != .systemBackground {
                webView.underPageBackgroundColor = .systemBackground
            }
        }
    }

    func applyWebDarkModeToAllTabs() {
        let profiles = syncEngine?.profiles ?? [.defaultProfile]
        for tab in tabs {
            guard let webView = tab.webView else { continue }
            let targetURL = webView.url ?? URL(string: tab.urlString)
            applyWebDarkAppearance(to: webView, url: targetURL)
            let profile = profiles.first(where: { $0.id == tab.profileId }) ?? .defaultProfile
            configureUserScripts(on: webView.configuration.userContentController, profile: profile, initialURL: targetURL)
            let enabled = effectiveWebDarkEnabled(for: targetURL)
            webView.evaluateJavaScript(
                "window.__prismSetWebDark && window.__prismSetWebDark(\(enabled ? "true" : "false"));",
                completionHandler: nil
            )
        }
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

    func savePendingPassword(usernameOverride: String? = nil) {
        guard let tab = activeTab, let pending = tab.pendingPasswordSave, let syncEngine else { return }
        let finalUser = (usernameOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (usernameOverride ?? pending.username)
            : pending.username
        let now = Date().timeIntervalSince1970 * 1000
        if let idx = syncEngine.passwords.firstIndex(where: { $0.origin == pending.origin && $0.username == finalUser }) {
            syncEngine.passwords[idx].password = pending.password
            syncEngine.passwords[idx].updatedAt = now
        } else {
            syncEngine.passwords.insert(
                PasswordEntry(
                    id: UUID().uuidString,
                    origin: pending.origin,
                    username: finalUser,
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
        if navigationAction.targetFrame?.isMainFrame == true {
            applyWebDarkAppearance(to: webView, url: url)
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
        applyWebDarkAppearance(to: webView, url: webView.url)
        syncWebViewState(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        applyWebDarkAppearance(to: webView, url: webView.url)
        let enabled = effectiveWebDarkEnabled(for: webView.url)
        webView.evaluateJavaScript(
            "window.__prismSetWebDark && window.__prismSetWebDark(\(enabled ? "true" : "false"));",
            completionHandler: nil
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        applyWebDarkAppearance(to: webView, url: webView.url)
        let enabled = effectiveWebDarkEnabled(for: webView.url)
        webView.evaluateJavaScript(
            "window.__prismSetWebDark && window.__prismSetWebDark(\(enabled ? "true" : "false"));",
            completionHandler: nil
        )
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

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        syncWebViewState(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        syncWebViewState(webView)
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

    func syncClipboardChangeCount() {
        lastClipboardChangeCount = UIPasteboard.general.changeCount
    }

    func extractHTTPURL(from text: String) -> URL? {
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

private enum WebDarkModeScripts {
    static func documentStartSource(
        initialEnabled: Bool,
        followThemeDark: Bool,
        whitelistHosts: Set<String>
    ) -> String {
        let whitelistArray = Array(whitelistHosts).sorted()
        let whitelistJSON: String = {
            guard let data = try? JSONEncoder().encode(whitelistArray),
                  let str = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return str
        }()
        let initialBool = initialEnabled ? "true" : "false"
        let followBool = followThemeDark ? "true" : "false"

        return """
        (function() {
          if (window.__prismWebDarkStartInstalled) return;
          window.__prismWebDarkStartInstalled = true;

          const whitelist = new Set(\(whitelistJSON));
          const globalFollowDark = \(followBool);
          const host = (location.hostname || '').toLowerCase();
          const isHttp = location.protocol === 'http:' || location.protocol === 'https:';
          const enabled = isHttp ? (globalFollowDark && !whitelist.has(host)) : \(initialBool);
          window.__prismWebDarkEnabled = enabled;

          function ensureColorSchemeMeta(on) {
            const ownMeta = document.querySelector('meta[data-prism-cs="1"]');
            if (!on) {
              if (ownMeta) ownMeta.remove();
              return;
            }
            const nativeMeta = document.querySelector('meta[name="color-scheme"]:not([data-prism-cs])');
            if (!nativeMeta && !ownMeta) {
              const target = document.head || document.documentElement;
              if (!target) return;
              const m = document.createElement('meta');
              m.setAttribute('name', 'color-scheme');
              m.setAttribute('content', 'dark light');
              m.setAttribute('data-prism-cs', '1');
              target.appendChild(m);
            }
          }

          function ensureDarkStyle() {
            if (document.getElementById('prism-dark-style')) return;
            const target = document.head || document.documentElement;
            if (!target) return;
            const style = document.createElement('style');
            style.id = 'prism-dark-style';
            style.textContent = `
              html[data-prism-dark="1"] {
                background-color: #ffffff !important;
                filter: invert(0.92) hue-rotate(180deg) contrast(0.96) !important;
              }
              html[data-prism-dark="1"] img,
              html[data-prism-dark="1"] video,
              html[data-prism-dark="1"] picture,
              html[data-prism-dark="1"] canvas,
              html[data-prism-dark="1"] iframe,
              html[data-prism-dark="1"] [style*="background-image"]:not(body):not(html) {
                filter: invert(1) hue-rotate(180deg) contrast(1.04) !important;
              }
              html[data-prism-dark="1"]:has(:fullscreen),
              html[data-prism-dark="1"]:has(:-webkit-full-screen) {
                filter: none !important;
              }
            `;
            target.appendChild(style);
          }

          function removePrepStyle() {
            const prep = document.getElementById('prism-dark-prep');
            if (prep) prep.remove();
          }

          if (enabled && document.documentElement) {
            ensureColorSchemeMeta(true);
            ensureDarkStyle();
            if (!document.getElementById('prism-dark-prep')) {
              const prep = document.createElement('style');
              prep.id = 'prism-dark-prep';
              prep.textContent = 'html, body { transition: background-color 0.12s ease !important; } html:not([data-prism-dark]) { background-color: #14171a !important; }';
              document.documentElement.appendChild(prep);
            }
          }

          window.__prismWebDarkEnsure = {
            ensureColorSchemeMeta,
            ensureDarkStyle,
            removePrepStyle
          };
        })();
        """
    }

    static func documentEndSource() -> String {
        return """
        (function() {
          if (window.__prismWebDarkEndInstalled) return;
          window.__prismWebDarkEndInstalled = true;

          const helper = window.__prismWebDarkEnsure || {
            ensureColorSchemeMeta: function() {},
            ensureDarkStyle: function() {},
            removePrepStyle: function() {}
          };

          function parseCssRgb(raw) {
            if (!raw || typeof raw !== 'string') return null;
            let m = raw.match(/rgba?\\(\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*,\\s*([\\d.]+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)/i);
            if (!m) {
              m = raw.match(/rgba?\\(\\s*([\\d.]+)\\s+([\\d.]+)\\s+([\\d.]+)(?:\\s*\\/\\s*([\\d.]+%?))?\\s*\\)/i);
            }
            if (!m) return null;
            const r = Number(m[1]);
            const g = Number(m[2]);
            const b = Number(m[3]);
            let a = 1;
            if (m[4] !== undefined) {
              a = String(m[4]).endsWith('%') ? parseFloat(m[4]) / 100 : Number(m[4]);
            }
            if (!Number.isFinite(r) || !Number.isFinite(g) || !Number.isFinite(b) || !Number.isFinite(a)) return null;
            if (a < 0.18) return null;
            const luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
            return { r, g, b, a, luminance };
          }

          function isAlreadyDarkPage() {
            const root = document.documentElement;
            if (!root) return false;

            const prevAttr = root.getAttribute('data-prism-dark');
            if (prevAttr === '1') {
              root.removeAttribute('data-prism-dark');
            }

            let foundDarkBg = false;
            let foundLightBg = false;

            try {
              const candidates = [];
              if (document.body) candidates.push(document.body);
              candidates.push(root);
              const mainEl = document.querySelector('main, #app, #root, #__next, #content, ytd-app');
              if (mainEl) candidates.push(mainEl);
              if (typeof document.elementFromPoint === 'function' && window.innerWidth > 20 && window.innerHeight > 20) {
                let ptEl = document.elementFromPoint(Math.floor(window.innerWidth * 0.5), Math.min(180, Math.floor(window.innerHeight * 0.35)));
                while (ptEl && ptEl !== document.body && ptEl !== root && candidates.length < 10) {
                  candidates.push(ptEl);
                  ptEl = ptEl.parentElement;
                }
              }

              for (let i = 0; i < candidates.length; i += 1) {
                const el = candidates[i];
                if (!el) continue;
                const parsed = parseCssRgb(getComputedStyle(el).backgroundColor);
                if (!parsed) continue;
                if (parsed.luminance < 0.38) {
                  foundDarkBg = true;
                } else {
                  foundLightBg = true;
                }
                break;
              }

              if (foundDarkBg) return true;
              if (foundLightBg) return false;

              const nativeMeta = document.querySelector('meta[name="color-scheme"]:not([data-prism-cs])');
              const metaCS = nativeMeta ? (nativeMeta.getAttribute('content') || '').toLowerCase() : '';
              const rootCS = (getComputedStyle(root).colorScheme || '').toLowerCase();
              return metaCS.includes('dark') || rootCS.includes('dark');
            } finally {
              if (prevAttr === '1' && window.__prismWebDarkEnabled) {
                root.setAttribute('data-prism-dark', '1');
              }
            }
          }

          function evaluateAndApply() {
            const root = document.documentElement;
            if (!root) return;
            helper.removePrepStyle();

            if (!window.__prismWebDarkEnabled) {
              helper.ensureColorSchemeMeta(false);
              root.removeAttribute('data-prism-dark');
              return;
            }

            helper.ensureColorSchemeMeta(true);
            helper.ensureDarkStyle();
            if (isAlreadyDarkPage()) {
              root.setAttribute('data-prism-dark', '0');
            } else {
              root.setAttribute('data-prism-dark', '1');
            }
          }

          window.__prismSetWebDark = function(enabled) {
            window.__prismWebDarkEnabled = Boolean(enabled);
            evaluateAndApply();
          };

          evaluateAndApply();
          if (typeof requestAnimationFrame === 'function') {
            requestAnimationFrame(evaluateAndApply);
          }
          setTimeout(evaluateAndApply, 250);
          setTimeout(evaluateAndApply, 950);

          let debounceTimer = null;
          const scheduleReeval = () => {
            if (!window.__prismWebDarkEnabled) return;
            if (debounceTimer) clearTimeout(debounceTimer);
            debounceTimer = setTimeout(evaluateAndApply, 180);
          };

          if (typeof MutationObserver === 'function' && document.documentElement) {
            const mo = new MutationObserver((mutations) => {
              if (!window.__prismWebDarkEnabled) return;
              for (let i = 0; i < mutations.length; i += 1) {
                const m = mutations[i];
                if (m.attributeName === 'data-prism-dark') continue;
                scheduleReeval();
                break;
              }
            });
            mo.observe(document.documentElement, {
              attributes: true,
              attributeFilter: ['class', 'style', 'data-color-mode', 'data-theme']
            });
            if (document.body) {
              mo.observe(document.body, {
                attributes: true,
                attributeFilter: ['class', 'style', 'data-theme']
              });
            }
          }
        })();
        """
    }
}
