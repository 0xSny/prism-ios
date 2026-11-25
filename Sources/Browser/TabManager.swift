import Foundation
import LocalAuthentication
import UIKit
import WebKit

struct PersistedTabItem: Codable, Identifiable, Equatable {
    var id: UUID
    var profileId: String
    var title: String
    var urlString: String
    var isNewTab: Bool
}

private struct PersistedSessionState: Codable {
    var tabs: [PersistedTabItem]
    var activeTabId: UUID?
}

@MainActor
protocol PrismTopColorHost: AnyObject {
    func applyTopColor(_ color: UIColor, from traitCollection: UITraitCollection?)
}

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
    @Published var isDesktopMode: Bool = false
    @Published var blockedCount: Int = 0
    @Published var isTranslated: Bool = false
    @Published var hasVideo: Bool = false
    @Published var videoPaused: Bool = true
    @Published var playbackRate: Double = 1.0
    @Published var sniffedMedia: [SniffedMediaItem] = []
    @Published var devToolsRevision: Int = 0
    @Published var matchedPasswords: [PasswordEntry] = []
    @Published var showAutofillBar: Bool = false
    @Published var pendingPasswordSave: (origin: String, username: String, password: String)?
    @Published var blockedAppJumpURL: URL?
    @Published var snapshot: UIImage?

    var videoSeconds: Double = 0
    var videoDuration: Double = 0
    var consoleLogs: [ConsoleLogEntry] = []
    var networkLogs: [NetworkLogEntry] = []

    var webView: WKWebView?
    var topBackdropColor: UIColor?
    var pendingSeekSeconds: Double? = nil
    var lastUserInteractionAt: TimeInterval = 0
    var lastActiveAt: TimeInterval = Date().timeIntervalSince1970
    var themeColorObservation: NSKeyValueObservation?
    var progressObservation: NSKeyValueObservation?
    var loadingObservation: NSKeyValueObservation?
    var titleObservation: NSKeyValueObservation?
    var urlObservation: NSKeyValueObservation?
    var backObservation: NSKeyValueObservation?
    var forwardObservation: NSKeyValueObservation?

    var isWithinUserGestureWindow: Bool {
        (Date().timeIntervalSince1970 - lastUserInteractionAt) <= 0.85
    }

    func markUserInteraction() {
        lastUserInteractionAt = Date().timeIntervalSince1970
    }

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

    func hibernate() {
        themeColorObservation?.invalidate()
        progressObservation?.invalidate()
        loadingObservation?.invalidate()
        titleObservation?.invalidate()
        urlObservation?.invalidate()
        backObservation?.invalidate()
        forwardObservation?.invalidate()
        themeColorObservation = nil
        progressObservation = nil
        loadingObservation = nil
        titleObservation = nil
        urlObservation = nil
        backObservation = nil
        forwardObservation = nil
        if let wv = webView {
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.configuration.userContentController.removeAllScriptMessageHandlers()
            wv.removeFromSuperview()
        }
        webView = nil
        isLoading = false
        estimatedProgress = 0
        // Intentionally preserve snapshot, title, urlString, and isNewTab for zero-jank tab switcher preview & lazy wake
    }

    func teardown() {
        hibernate()
        snapshot = nil
    }
}

@MainActor
final class TabManager: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    static let standardDarkBackdropColor = UIColor(red: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1C / 255.0, alpha: 1.0)
    static let standardLightBackdropColor = UIColor.white
    static let dynamicSystemBackdropColor = UIColor { trait in
        trait.userInterfaceStyle == .dark ? standardDarkBackdropColor : standardLightBackdropColor
    }

    @Published var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID? {
        didSet {
            guard !isRestoringSession else { return }
            if let nextId = activeTabId, nextId != oldValue {
                let targetTab = tabs.first(where: { $0.id == nextId })
                targetTab?.lastActiveAt = Date().timeIntervalSince1970
                if nextId != skipAutoLazyLoadTabId {
                    loadLazyWebViewIfNeeded(for: targetTab)
                }
                enforceBackgroundTabMemoryLimit()
            }
            scheduleSessionSave()
        }
    }
    @Published var activeToast: ToastNotice?
    @Published var recentlyClosedTabs: [PersistedTabItem] = []
    @Published var hasClipboardWebURL: Bool = false
    @Published var searchEngine: SearchEngineOption = .google {
        didSet {
            UserDefaults.standard.set(searchEngine.rawValue, forKey: "prism.searchEngine")
            if !isApplyingRemoteSettings {
                syncEngine?.notifyScopeDirty("settings")
            }
        }
    }
    @Published var appTheme: AppTheme = .system {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "prism.theme")
            switch appTheme {
            case .dark: StatusBarStyleManager.shared.applyWindowOverride(.dark)
            case .light: StatusBarStyleManager.shared.applyWindowOverride(.light)
            case .system: StatusBarStyleManager.shared.applyWindowOverride(.unspecified)
            }
            applyWebDarkModeToAllTabs()
            if !isApplyingRemoteSettings {
                syncEngine?.notifyScopeDirty("settings")
            }
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
    @Published var adblockEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(adblockEnabled, forKey: "prism.adblockEnabled")
            applyAdblockToAllTabs()
        }
    }
    @Published var blockRogueAppJumps: Bool = true {
        didSet {
            UserDefaults.standard.set(blockRogueAppJumps, forKey: "prism.blockRogueAppJumps")
            syncAppJumpShieldToAllTabs()
            if !isApplyingRemoteSettings {
                syncEngine?.notifyScopeDirty("settings")
            }
        }
    }
    @Published var appJumpWhitelistHosts: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(appJumpWhitelistHosts).sorted(), forKey: "prism.appJumpWhitelistHosts")
            syncAppJumpShieldToAllTabs()
        }
    }
    var desktopMode: Bool {
        get { activeTab?.isDesktopMode ?? false }
        set {
            guard let tab = activeTab else { return }
            tab.isDesktopMode = newValue
            objectWillChange.send()
        }
    }
    @Published var omniboxEnterTopHitEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(omniboxEnterTopHitEnabled, forKey: "prism.omniboxEnterTopHitEnabled")
            if !isApplyingRemoteSettings {
                syncEngine?.notifyScopeDirty("settings")
            }
        }
    }
    @Published var downloads: [DownloadRecord] = []

    weak var syncEngine: SyncEngine?
    weak var handoffService: HandoffService?

    private static let allowWithoutAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

    private var lastClipboardChangeCount: Int = UIPasteboard.general.changeCount
    private var lastPromptedClipboard: String = ""
    private var allowedOnceJumpURL: URL?
    private var allowedOnceJumpExpiresAt: TimeInterval = 0
    private var isApplyingRemoteSettings: Bool = false
    private var isRestoringSession: Bool = false
    private var skipAutoLazyLoadTabId: UUID?
    private var sessionSaveTask: Task<Void, Never>?
    private var blockedAppBannerDismissTask: Task<Void, Never>?
    private var systemIsDark: Bool = UITraitCollection.current.userInterfaceStyle == .dark
    private var devToolsActive: Bool = false
    private var downloadMap: [ObjectIdentifier: UUID] = [:]

    private let sessionFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("tabs-session.json")
    }()

    override init() {
        super.init()
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 160 * 1024 * 1024)
        isApplyingRemoteSettings = true
        defer { isApplyingRemoteSettings = false }
        if let rawEngine = UserDefaults.standard.string(forKey: "prism.searchEngine"),
           let eng = SearchEngineOption(rawValue: rawEngine) {
            self.searchEngine = eng
        }
        if let rawTheme = UserDefaults.standard.string(forKey: "prism.theme"),
           let theme = AppTheme(rawValue: rawTheme) {
            self.appTheme = theme
        }
        if UserDefaults.standard.object(forKey: "prism.adblockEnabled") != nil {
            self.adblockEnabled = UserDefaults.standard.bool(forKey: "prism.adblockEnabled")
        }
        if UserDefaults.standard.object(forKey: "prism.blockRogueAppJumps") != nil {
            self.blockRogueAppJumps = UserDefaults.standard.bool(forKey: "prism.blockRogueAppJumps")
        } else {
            UserDefaults.standard.set(true, forKey: "prism.blockRogueAppJumps")
        }
        if let savedJumpHosts = UserDefaults.standard.stringArray(forKey: "prism.appJumpWhitelistHosts") {
            self.appJumpWhitelistHosts = Set(
                savedJumpHosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
            )
        }
        if UserDefaults.standard.object(forKey: "prism.omniboxEnterTopHitEnabled") != nil {
            self.omniboxEnterTopHitEnabled = UserDefaults.standard.bool(forKey: "prism.omniboxEnterTopHitEnabled")
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
        BackgroundMediaController.shared.onRemoteCommand = { [weak self] action, positionSeconds in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let targetTab = self.tabs.first(where: { $0.hasVideo && !$0.videoPaused }) ?? self.activeTab,
                      let webView = targetTab.webView else { return }
                switch action {
                case "play":
                    webView.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('play');", completionHandler: nil)
                case "pause":
                    webView.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('pause');", completionHandler: nil)
                case "toggle", "togglePlay":
                    webView.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('togglePlay');", completionHandler: nil)
                case "seek", "seekTo":
                    let sec = max(0, positionSeconds ?? 0)
                    webView.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('seekTo', \(sec));", completionHandler: nil)
                default:
                    break
                }
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarningNotification),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        restoreSessionOrCreateDefault()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleMemoryWarningNotification() {
        hibernateAllBackgroundTabs()
    }

    private func hibernateAllBackgroundTabs() {
        for tab in tabs {
            guard tab.id != activeTabId, tab.webView != nil else { continue }
            tab.hibernate()
        }
    }

    private func enforceBackgroundTabMemoryLimit(maxLiveTabs: Int = 6) {
        let liveTabs = tabs.filter { $0.webView != nil }
        guard liveTabs.count > maxLiveTabs else { return }
        let candidates = liveTabs
            .filter { tab in
                if tab.id == activeTabId { return false }
                // Exempt tabs currently playing audio/video
                if tab.hasVideo && !tab.videoPaused { return false }
                return true
            }
            .sorted { $0.lastActiveAt < $1.lastActiveAt }

        let excessCount = liveTabs.count - maxLiveTabs
        for tab in candidates.prefix(excessCount) {
            tab.hibernate()
        }
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

    var isActiveTabAppJumpWhitelisted: Bool {
        guard let host = activeTabHTTPHost else { return false }
        return appJumpWhitelistHosts.contains(host)
    }

    func isHostAppJumpWhitelisted(_ url: URL?) -> Bool {
        guard let host = normalizedHTTPHost(from: url) else { return false }
        return appJumpWhitelistHosts.contains(host)
    }

    func toggleAppJumpWhitelistForActiveTab() {
        guard let host = activeTabHTTPHost else { return }
        if appJumpWhitelistHosts.contains(host) {
            appJumpWhitelistHosts.remove(host)
            showToast(L10n.t("已恢复此网站防强跳拦截", "App jump blocker restored for this site"))
        } else {
            appJumpWhitelistHosts.insert(host)
            showToast(L10n.t("已允许此网站打开外部 App", "External app opening allowed for this site"))
        }
    }

    func clearAppJumpWhitelist() {
        appJumpWhitelistHosts.removeAll()
    }

    var activeTab: BrowserTab? {
        tabs.first(where: { $0.id == activeTabId }) ?? tabs.first
    }

    var activeProfile: BrowserProfile {
        let profiles = syncEngine?.profiles ?? [.defaultProfile]
        let pid = activeTab?.profileId ?? "default"
        return profiles.first(where: { $0.id == pid }) ?? profiles.first ?? .defaultProfile
    }

    // MARK: - Session Persistence & Lazy Tab Loading

    private func restoreSessionOrCreateDefault() {
        if let data = try? Data(contentsOf: sessionFileURL),
           let saved = try? JSONDecoder().decode(PersistedSessionState.self, from: data),
           !saved.tabs.isEmpty {
            isRestoringSession = true
            var restored: [BrowserTab] = []
            for item in saved.tabs {
                let targetURL = item.isNewTab ? nil : URL(string: item.urlString)
                let tab = BrowserTab(id: item.id, profileId: item.profileId, initialURL: targetURL)
                tab.isNewTab = item.isNewTab || targetURL == nil
                tab.urlString = item.isNewTab ? "" : item.urlString
                if !item.title.isEmpty {
                    tab.title = item.title
                }
                restored.append(tab)
            }
            self.tabs = restored
            if let savedActive = saved.activeTabId, restored.contains(where: { $0.id == savedActive }) {
                self.activeTabId = savedActive
            } else {
                self.activeTabId = restored.first?.id
            }
            isRestoringSession = false
            // Only instantiate WKWebView for the visible active tab at cold launch (0ms background lazy restore)
            loadLazyWebViewIfNeeded(for: activeTab)
            return
        }
        createTab(url: nil, activate: true)
    }

    func loadLazyWebViewIfNeeded(for tab: BrowserTab?) {
        guard let tab, !tab.isNewTab, tab.webView == nil,
              let url = URL(string: tab.urlString), !tab.urlString.isEmpty else {
            return
        }
        load(url: url, in: tab)
    }

    func scheduleSessionSave() {
        guard !isRestoringSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSessionImmediately()
        }
    }

    func saveSessionImmediately() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        let items = tabs.map { tab in
            PersistedTabItem(
                id: tab.id,
                profileId: tab.profileId,
                title: tab.title,
                urlString: tab.urlString,
                isNewTab: tab.isNewTab
            )
        }
        let state = PersistedSessionState(tabs: items, activeTabId: activeTabId)
        let targetURL = sessionFileURL
        if let data = try? JSONEncoder().encode(state) {
            Task.detached(priority: .utility) {
                try? data.write(to: targetURL, options: .atomic)
            }
        }
    }

    private func recordClosedTabIfEligible(_ tab: BrowserTab) {
        guard !tab.isNewTab, !tab.urlString.isEmpty else { return }
        let entry = PersistedTabItem(
            id: tab.id,
            profileId: tab.profileId,
            title: tab.title,
            urlString: tab.urlString,
            isNewTab: false
        )
        recentlyClosedTabs.removeAll { $0.urlString == entry.urlString }
        recentlyClosedTabs.insert(entry, at: 0)
        if recentlyClosedTabs.count > 5 {
            recentlyClosedTabs = Array(recentlyClosedTabs.prefix(5))
        }
    }

    func restoreLastClosedTab() {
        guard !recentlyClosedTabs.isEmpty else { return }
        let entry = recentlyClosedTabs.removeFirst()
        let url = URL(string: entry.urlString)
        let restored = createTab(url: url, profileId: entry.profileId, activate: true)
        if !entry.title.isEmpty {
            restored.title = entry.title
        }
    }

    @discardableResult
    func createTab(url: URL? = nil, profileId: String? = nil, activate: Bool = true, seekSeconds: Double? = nil) -> BrowserTab {
        if activate {
            captureActiveSnapshot()
        }
        let pid = profileId ?? activeProfile.id
        let tab = BrowserTab(profileId: pid, initialURL: url)
        tabs.append(tab)
        if activate {
            skipAutoLazyLoadTabId = tab.id
            activeTabId = tab.id
            skipAutoLazyLoadTabId = nil
        }
        if let url {
            load(url: url, in: tab, seekSeconds: seekSeconds)
        }
        scheduleSessionSave()
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        recordClosedTabIfEligible(tabs[idx])
        tabs[idx].teardown()
        tabs.remove(at: idx)
        if tabs.isEmpty {
            createTab(url: nil, activate: true)
            return
        }
        if activeTabId == id {
            let nextIdx = min(idx, tabs.count - 1)
            activeTabId = tabs[nextIdx].id
        }
        scheduleSessionSave()
    }

    func closeOtherTabs(keeping keepId: UUID) {
        for tab in tabs where tab.id != keepId {
            recordClosedTabIfEligible(tab)
            tab.teardown()
        }
        tabs.removeAll { $0.id != keepId }
        if tabs.isEmpty {
            createTab(url: nil, activate: true)
            return
        }
        activeTabId = keepId
        scheduleSessionSave()
    }

    func closeAllTabs() {
        for tab in tabs {
            recordClosedTabIfEligible(tab)
            tab.teardown()
        }
        tabs.removeAll()
        createTab(url: nil, activate: true)
    }

    func switchTab(byOffset offset: Int) {
        guard tabs.count > 1, let curId = activeTabId,
              let curIdx = tabs.firstIndex(where: { $0.id == curId }) else { return }
        captureActiveSnapshot()
        let nextIdx = (curIdx + offset + tabs.count) % tabs.count
        activeTabId = tabs[nextIdx].id
    }

    func activateTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if activeTabId != id {
            captureActiveSnapshot()
            activeTabId = id
        }
    }

    func captureActiveSnapshot() {
        guard let tab = activeTab, !tab.isNewTab, let webView = tab.webView else { return }
        guard webView.bounds.width > 10, webView.bounds.height > 10 else { return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.snapshotWidth = 360
        webView.takeSnapshot(with: config) { [weak tab] image, _ in
            guard let image, let tab else { return }
            Task { @MainActor in
                tab.snapshot = image
            }
        }
    }

    func setDevToolsActive(_ active: Bool) {
        devToolsActive = active
        let jsFlag = active ? "true" : "false"
        for tab in tabs {
            tab.webView?.evaluateJavaScript("window.__prismDevToolsEnabled = \(jsFlag);", completionHandler: nil)
        }
    }

    func applyAdblockToAllTabs() {
        let profiles = syncEngine?.profiles ?? [.defaultProfile]
        for tab in tabs {
            guard let webView = tab.webView else { continue }
            let profile = profiles.first(where: { $0.id == tab.profileId }) ?? .defaultProfile
            AdBlockManager.shared.apply(to: webView.configuration.userContentController, enabled: adblockEnabled && profile.fingerprint.blockTrackers)
        }
    }

    func applyRemotePortableSettings(_ remote: PortableSettings) {
        if let theme = remote.theme, appTheme != theme {
            isApplyingRemoteSettings = true
            appTheme = theme
            isApplyingRemoteSettings = false
        }
        if let engine = remote.searchEngine, searchEngine != engine {
            isApplyingRemoteSettings = true
            searchEngine = engine
            isApplyingRemoteSettings = false
        }
        if let blockJumps = remote.blockRogueAppJumps, blockRogueAppJumps != blockJumps {
            isApplyingRemoteSettings = true
            blockRogueAppJumps = blockJumps
            isApplyingRemoteSettings = false
        }
        if let enterTopHit = remote.omniboxEnterTopHitEnabled, omniboxEnterTopHitEnabled != enterTopHit {
            isApplyingRemoteSettings = true
            omniboxEnterTopHitEnabled = enterTopHit
            isApplyingRemoteSettings = false
        }
    }

    func syncAppJumpShieldToAllTabs() {
        let profiles = syncEngine?.profiles ?? [.defaultProfile]
        for tab in tabs {
            guard let webView = tab.webView else { continue }
            let profile = profiles.first(where: { $0.id == tab.profileId }) ?? .defaultProfile
            let pageURL = webView.url ?? URL(string: tab.urlString)
            let enabled = blockRogueAppJumps && profile.fingerprint.blockTrackers && !isHostAppJumpWhitelisted(pageURL)
            configureUserScripts(on: webView.configuration.userContentController, profile: profile, initialURL: pageURL)
            webView.evaluateJavaScript(
                "window.__prismSetAppJumpShield && window.__prismSetAppJumpShield(\(enabled ? "true" : "false"));",
                completionHandler: nil
            )
        }
    }

    func markActiveTabUserInteraction() {
        activeTab?.markUserInteraction()
    }

    func extractReaderArticle(completion: @escaping (ReaderArticle?) -> Void) {
        guard let tab = activeTab, !tab.isNewTab, let webView = tab.webView else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(MediaSnifferScripts.extractReaderJS) { result, _ in
            guard let dict = result as? [String: Any],
                  let paragraphs = dict["paragraphs"] as? [String],
                  !paragraphs.isEmpty else {
                Task { @MainActor in completion(nil) }
                return
            }
            let article = ReaderArticle(
                title: (dict["title"] as? String) ?? tab.title,
                byline: (dict["byline"] as? String) ?? "",
                siteHost: (dict["siteHost"] as? String) ?? "",
                paragraphs: paragraphs
            )
            Task { @MainActor in completion(article) }
        }
    }

    func findInActivePage(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab = activeTab, !tab.isNewTab, let webView = tab.webView else { return }
        webView.isFindInteractionEnabled = true
        if !trimmed.isEmpty {
            webView.findInteraction?.searchText = trimmed
        }
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
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
        tab.topBackdropColor = nil
        tab.matchedPasswords = []
        tab.showAutofillBar = false
        tab.blockedAppJumpURL = nil
        tab.pendingSeekSeconds = (seekSeconds ?? 0) > 0 ? seekSeconds : nil
        applyWebDarkAppearance(to: webView, url: url)
        webView.load(URLRequest(url: url))
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
        let bridgeHandler = WeakScriptMessageHandler(self)
        ucc.add(bridgeHandler, name: "prismBridge")
        ucc.add(bridgeHandler, name: "prismTopColor")
        configureUserScripts(on: ucc, profile: profile, initialURL: URL(string: tab.urlString))
        AdBlockManager.shared.apply(to: ucc, enabled: adblockEnabled && profile.fingerprint.blockTrackers)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        if tab.isDesktopMode {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        } else if let customUA = profile.fingerprint.userAgent, !customUA.isEmpty {
            webView.customUserAgent = customUA
        }
        tab.webView = webView

        tab.progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak tab, weak webView] _, _ in
            Task { @MainActor [weak tab, weak webView] in
                guard let tab, let webView else { return }
                let p = webView.estimatedProgress
                if abs(tab.estimatedProgress - p) > 0.015 || p >= 1.0 || p <= 0.01 {
                    tab.estimatedProgress = p
                }
            }
        }
        tab.loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak tab, weak webView] _, _ in
            Task { @MainActor [weak tab, weak webView] in
                guard let tab, let webView else { return }
                if tab.isLoading != webView.isLoading {
                    tab.isLoading = webView.isLoading
                }
            }
        }
        tab.titleObservation = webView.observe(\.title, options: [.new]) { [weak tab, weak webView] _, _ in
            Task { @MainActor [weak tab, weak webView] in
                guard let tab, let webView else { return }
                if let nextTitle = webView.title, !nextTitle.isEmpty, tab.title != nextTitle {
                    tab.title = nextTitle
                }
            }
        }
        tab.urlObservation = webView.observe(\.url, options: [.new]) { [weak tab, weak webView] _, _ in
            Task { @MainActor [weak tab, weak webView] in
                guard let tab, let webView else { return }
                if let nextUrl = webView.url?.absoluteString, !nextUrl.isEmpty, tab.urlString != nextUrl {
                    tab.urlString = nextUrl
                }
            }
        }
        tab.backObservation = webView.observe(\.canGoBack, options: [.new]) { [weak tab, weak webView] _, _ in
            Task { @MainActor [weak tab, weak webView] in
                guard let tab, let webView else { return }
                if tab.canGoBack != webView.canGoBack {
                    tab.canGoBack = webView.canGoBack
                }
            }
        }
        tab.forwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak tab, weak webView] _, _ in
            Task { @MainActor [weak tab, weak webView] in
                guard let tab, let webView else { return }
                if tab.canGoForward != webView.canGoForward {
                    tab.canGoForward = webView.canGoForward
                }
            }
        }
        tab.themeColorObservation = webView.observe(\.themeColor, options: [.new]) { [weak self, weak tab, weak webView] _, _ in
            Task { @MainActor [weak self, weak tab, weak webView] in
                guard let self, let tab, let webView else { return }
                if let themeColor = webView.themeColor {
                    self.applySampledTopColor(themeColor, to: webView, for: tab)
                } else {
                    webView.evaluateJavaScript("window.__prismSampleTopColor && window.__prismSampleTopColor(true);", completionHandler: nil)
                }
            }
        }
        applyWebDarkAppearance(to: webView, url: URL(string: tab.urlString))
        return webView
    }

    private func configureUserScripts(on ucc: WKUserContentController, profile: BrowserProfile, initialURL: URL?) {
        ucc.removeAllUserScripts()
        let shieldEnabled = blockRogueAppJumps && profile.fingerprint.blockTrackers && !isHostAppJumpWhitelisted(initialURL)
        let shieldSource = AppJumpShield.antiHijackScriptSource(enabled: shieldEnabled)
        ucc.addUserScript(WKUserScript(source: shieldSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: MediaSnifferScripts.injectScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: MediaSnifferScripts.imeCodeMirrorHealerSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if devToolsActive {
            ucc.addUserScript(WKUserScript(source: "window.__prismDevToolsEnabled = true;", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let fpScript = ProfileDataStoreRegistry.shared.fingerprintUserScript(for: profile) {
            ucc.addUserScript(fpScript)
        }
        let startScript = WebDarkModeScripts.documentStartSource(
            themeMode: appTheme.rawValue,
            followThemeDark: webDarkModeFollowTheme,
            whitelistHosts: webDarkModeWhitelistHosts
        )
        let endScript = WebDarkModeScripts.documentEndSource()
        ucc.addUserScript(WKUserScript(source: startScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: endScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func fallbackBackdropColor(for url: URL?, trait: UITraitCollection? = nil) -> UIColor {
        let isWhitelisted: Bool = {
            guard let host = normalizedHTTPHost(from: url) else { return false }
            return webDarkModeWhitelistHosts.contains(host)
        }()
        if !webDarkModeFollowTheme || isWhitelisted || appTheme == .light {
            return Self.standardLightBackdropColor
        }
        if appTheme == .dark {
            return Self.standardDarkBackdropColor
        }
        if let trait {
            return trait.userInterfaceStyle == .dark ? Self.standardDarkBackdropColor : Self.standardLightBackdropColor
        }
        return Self.dynamicSystemBackdropColor
    }

    func applyWebDarkAppearance(to webView: WKWebView, url: URL? = nil, trait: UITraitCollection? = nil) {
        let targetURL = url ?? webView.url
        let isWhitelisted: Bool = {
            guard let host = normalizedHTTPHost(from: targetURL) else { return false }
            return webDarkModeWhitelistHosts.contains(host)
        }()

        let targetStyle: UIUserInterfaceStyle
        if !webDarkModeFollowTheme || isWhitelisted {
            targetStyle = .light
        } else {
            switch appTheme {
            case .dark:
                targetStyle = .dark
            case .light:
                targetStyle = .light
            case .system:
                targetStyle = .unspecified
            }
        }

        if webView.overrideUserInterfaceStyle != targetStyle {
            webView.overrideUserInterfaceStyle = targetStyle
        }
        if webView.isOpaque {
            webView.isOpaque = false
        }

        let tab = tabs.first(where: { $0.webView === webView })
        let effectiveTrait = trait ?? webView.superview?.traitCollection ?? UITraitCollection.current
        let resolvedColor = tab?.topBackdropColor ?? fallbackBackdropColor(for: targetURL, trait: effectiveTrait)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        webView.backgroundColor = resolvedColor
        webView.scrollView.backgroundColor = resolvedColor
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = resolvedColor
        }
        if let host = webView.superview as? PrismTopColorHost {
            host.applyTopColor(resolvedColor, from: effectiveTrait)
        }
        CATransaction.commit()

        if tab?.id == activeTabId, let activeTab = tab, !activeTab.isNewTab {
            StatusBarStyleManager.shared.applyStyle(for: resolvedColor, fallbackTrait: effectiveTrait)
        }
    }

    func applySampledTopColor(_ color: UIColor, to webView: WKWebView, for tab: BrowserTab? = nil) {
        let targetTab = tab ?? tabs.first(where: { $0.webView === webView })
        targetTab?.topBackdropColor = color
        let effectiveTrait = webView.superview?.traitCollection ?? UITraitCollection.current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = color
        }
        if let host = webView.superview as? PrismTopColorHost {
            host.applyTopColor(color, from: effectiveTrait)
        }
        CATransaction.commit()
        if targetTab?.id == activeTabId {
            StatusBarStyleManager.shared.applyStyle(for: color, fallbackTrait: effectiveTrait)
        }
    }

    func handleNativeTraitAppearanceChange(
        isDarkNow: Bool,
        webView: WKWebView?,
        trait: UITraitCollection
    ) {
        guard UIApplication.shared.applicationState != .background else { return }
        if let ws = webView?.window?.windowScene, ws.activationState == .background {
            return
        }
        systemIsDark = isDarkNow
        guard let webView else { return }
        if let tab = tabs.first(where: { $0.webView === webView }) {
            tab.topBackdropColor = nil
        }
        let baselineColor = fallbackBackdropColor(for: webView.url, trait: trait)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        webView.backgroundColor = baselineColor
        webView.scrollView.backgroundColor = baselineColor
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = baselineColor
        }
        if let host = webView.superview as? PrismTopColorHost {
            host.applyTopColor(baselineColor, from: trait)
        }
        CATransaction.commit()
        StatusBarStyleManager.shared.applyStyle(for: baselineColor, fallbackTrait: trait)
        webView.evaluateJavaScript(
            "window.__prismOnTraitChanged && window.__prismOnTraitChanged();",
            completionHandler: nil
        )
    }

    func syncAppearanceOnForegroundResume(window: UIWindow?) {
        let effectiveTrait = window?.traitCollection ?? UITraitCollection.current
        let actualDark = effectiveTrait.userInterfaceStyle == .dark
        let changed = (systemIsDark != actualDark)
        systemIsDark = actualDark

        let whitelistJSON: String = {
            guard let data = try? JSONEncoder().encode(Array(webDarkModeWhitelistHosts).sorted()),
                  let str = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return str
        }()
        let followStr = webDarkModeFollowTheme ? "true" : "false"

        for tab in tabs {
            if changed {
                tab.topBackdropColor = nil
            }
            guard let webView = tab.webView else { continue }
            let targetURL = webView.url ?? URL(string: tab.urlString)
            applyWebDarkAppearance(to: webView, url: targetURL, trait: effectiveTrait)
            let enabled = effectiveWebDarkEnabled(for: targetURL)
            webView.evaluateJavaScript(
                "window.__prismSyncConfig && window.__prismSyncConfig(\"\(appTheme.rawValue)\", \(followStr), \(whitelistJSON)); window.__prismSetWebDark && window.__prismSetWebDark(\(enabled ? "true" : "false")); window.__prismOnTraitChanged && window.__prismOnTraitChanged();",
                completionHandler: nil
            )
        }
    }

    func applyWebDarkModeToAllTabs() {
        let profiles = syncEngine?.profiles ?? [.defaultProfile]
        let whitelistJSON: String = {
            guard let data = try? JSONEncoder().encode(Array(webDarkModeWhitelistHosts).sorted()),
                  let str = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return str
        }()
        for tab in tabs {
            tab.topBackdropColor = nil
            guard let webView = tab.webView else { continue }
            let targetURL = webView.url ?? URL(string: tab.urlString)
            applyWebDarkAppearance(to: webView, url: targetURL)
            let profile = profiles.first(where: { $0.id == tab.profileId }) ?? .defaultProfile
            configureUserScripts(on: webView.configuration.userContentController, profile: profile, initialURL: targetURL)
            let enabled = effectiveWebDarkEnabled(for: targetURL)
            let followStr = webDarkModeFollowTheme ? "true" : "false"
            webView.evaluateJavaScript(
                "window.__prismSyncConfig && window.__prismSyncConfig(\"\(appTheme.rawValue)\", \(followStr), \(whitelistJSON)); window.__prismSetWebDark && window.__prismSetWebDark(\(enabled ? "true" : "false"));",
                completionHandler: nil
            )
        }
    }

    func switchProfileForActiveTab(_ profileId: String) {
        guard let tab = activeTab else { return }
        let currentUrl = URL(string: tab.urlString)
        tab.teardown()
        tab.profileId = profileId
        if !tab.isNewTab, let currentUrl {
            load(url: currentUrl, in: tab)
        }
    }

    func toggleDesktopUserAgent() {
        guard let tab = activeTab else { return }
        tab.isDesktopMode.toggle()
        objectWillChange.send()
        guard let webView = tab.webView else { return }
        if tab.isDesktopMode {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        } else {
            let profile = (syncEngine?.profiles ?? [.defaultProfile]).first(where: { $0.id == tab.profileId }) ?? .defaultProfile
            let ua = profile.fingerprint.userAgent
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
        showToast(L10n.t("正在翻译网页...", "Translating page..."))
        webView.evaluateJavaScript(TranslatorService.collectNodesJS) { [weak self, weak tab, weak webView] result, _ in
            guard let self, let tab, let webView else { return }
            guard let dict = result as? [String: Any] else {
                Task { @MainActor in
                    self.showToast(L10n.t("未检测到可翻译正文", "No translatable text found"))
                }
                return
            }
            if (dict["toggleOn"] as? Bool) == true {
                Task { @MainActor in tab.isTranslated = true }
                return
            }
            guard let texts = dict["texts"] as? [String], !texts.isEmpty else {
                Task { @MainActor in
                    self.showToast(L10n.t("未检测到可翻译正文", "No translatable text found"))
                }
                return
            }
            Task {
                let (translated, ok) = await TranslatorService.translateBatch(texts)
                guard ok else {
                    await MainActor.run {
                        tab.isTranslated = false
                        self.showToast(L10n.t("翻译请求失败，请检查网络后重试", "Translation failed, please try again"))
                    }
                    return
                }
                let applyJS = TranslatorService.applyTranslationsJS(translated)
                await MainActor.run {
                    webView.evaluateJavaScript(applyJS) { _, err in
                        Task { @MainActor in
                            if err == nil {
                                tab.isTranslated = true
                            } else {
                                tab.isTranslated = false
                                self.showToast(L10n.t("应用译文失败", "Failed to apply translations"))
                            }
                        }
                    }
                }
            }
        }
    }

    func toggleBookmarkCurrentPage() {
        guard let tab = activeTab, !tab.isNewTab, !tab.urlString.isEmpty, let syncEngine else { return }
        if let idx = syncEngine.bookmarks.firstIndex(where: { $0.url == tab.urlString }) {
            let existing = syncEngine.bookmarks[idx]
            syncEngine.recordDeletedBookmark(existing)
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
            syncEngine.markBookmarkChanged(item)
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
        allowedOnceJumpExpiresAt = Date().timeIntervalSince1970 + 3.0
        blockedAppBannerDismissTask?.cancel()
        blockedAppBannerDismissTask = nil
        activeTab?.blockedAppJumpURL = nil
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func showBlockedAppJumpBanner(_ url: URL, on tab: BrowserTab?) {
        guard let tab else { return }
        tab.blockedAppJumpURL = url
        blockedAppBannerDismissTask?.cancel()
        blockedAppBannerDismissTask = Task { @MainActor [weak tab] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let tab else { return }
            if tab.blockedAppJumpURL == url {
                tab.blockedAppJumpURL = nil
            }
        }
    }

    private func confirmSystemCommunicationURL(_ url: URL) {
        let scheme = (url.scheme ?? "").lowercased()
        let title = L10n.t("打开外部通信应用", "Open System App")
        let targetText = url.absoluteString
        let actionLabel: String = {
            switch scheme {
            case "tel", "facetime", "facetime-audio":
                return L10n.t("呼叫", "Call")
            case "sms":
                return L10n.t("发送短信", "Message")
            case "mailto":
                return L10n.t("发送邮件", "Mail")
            default:
                return L10n.t("打开", "Open")
            }
        }()

        let alert = UIAlertController(title: title, message: targetText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("取消", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: actionLabel, style: .default) { _ in
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        })
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
           let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController {
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(alert, animated: true)
        }
    }

    private func evaluateAppJumpShieldPolicy(
        for url: URL,
        in webView: WKWebView,
        isMainFrame: Bool,
        isNewWindow: Bool
    ) -> WKNavigationActionPolicy {
        let now = Date().timeIntervalSince1970
        let isAllowedOnce: Bool
        if let allowed = allowedOnceJumpURL, allowed == url, now <= allowedOnceJumpExpiresAt {
            isAllowedOnce = true
            allowedOnceJumpURL = nil
            allowedOnceJumpExpiresAt = 0
        } else {
            if allowedOnceJumpURL != nil && now > allowedOnceJumpExpiresAt {
                allowedOnceJumpURL = nil
                allowedOnceJumpExpiresAt = 0
            }
            isAllowedOnce = false
        }

        let tab = tabs.first(where: { $0.webView === webView })
        let profiles = syncEngine?.profiles ?? [.defaultProfile]
        let profile = profiles.first(where: { $0.id == tab?.profileId }) ?? .defaultProfile
        let currentURL = webView.url ?? tab.flatMap { URL(string: $0.urlString) }
        let shieldEnabled = blockRogueAppJumps && profile.fingerprint.blockTrackers && !isHostAppJumpWhitelisted(currentURL)
        let withinGesture = tab?.isWithinUserGestureWindow ?? false

        let decision = AppJumpShield.evaluateNavigation(
            url: url,
            currentTabURL: currentURL,
            isMainFrame: isMainFrame,
            withinGestureWindow: withinGesture,
            shieldEnabled: shieldEnabled,
            isAllowedOnce: isAllowedOnce
        )

        switch decision {
        case .allowNormal:
            let scheme = (url.scheme ?? "").lowercased()
            if shieldEnabled && (scheme == "http" || scheme == "https") {
                return Self.allowWithoutAppLink
            }
            return .allow
        case .cancelSilently(let incrementBlocked):
            if incrementBlocked {
                tab?.blockedCount += 1
            }
            return .cancel
        case .redirectInWebView(let cleanURL):
            tab?.blockedCount += 1
            if isNewWindow {
                createTab(url: cleanURL, profileId: tab?.profileId, activate: true)
            } else {
                webView.load(URLRequest(url: cleanURL))
            }
            return .cancel
        case .promptExternalApp(let externalURL, _):
            tab?.blockedCount += 1
            showBlockedAppJumpBanner(externalURL, on: tab)
            return .cancel
        case .promptSystemCommunication(let sysURL):
            confirmSystemCommunicationURL(sysURL)
            return .cancel
        }
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
        let entry: PasswordEntry
        if let idx = syncEngine.passwords.firstIndex(where: { $0.origin == pending.origin && $0.username == finalUser }) {
            var updated = syncEngine.passwords[idx]
            updated.password = pending.password
            updated.updatedAt = now
            entry = updated
        } else {
            entry = PasswordEntry(
                id: UUID().uuidString,
                origin: pending.origin,
                username: finalUser,
                password: pending.password,
                note: nil,
                createdAt: now,
                updatedAt: now
            )
        }
        syncEngine.markPasswordChanged(entry)
        tab.pendingPasswordSave = nil
        showToast(L10n.t("已加密保存并同步密码", "Password saved & encrypted"))
    }

    func pushSmartClipboardToDesktop() {
        guard let syncEngine, syncEngine.loggedIn, let handoffService else {
            showToast(L10n.t("请先登录 Prism Account 后再发送", "Sign in to Prism Account first"))
            return
        }
        let board = UIPasteboard.general
        if board.hasImages, let img = board.image {
            showToast(L10n.t("正在压缩并加密发送图片...", "Compressing & sending image..."))
            Task {
                let ok = await handoffService.pushImage(image: img, title: L10n.t("剪贴板图片", "Clipboard Image"), syncEngine: syncEngine)
                if ok {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    showToast(L10n.t("✅ 已加密发送剪贴板图片至电脑", "✅ Clipboard image sent to desktop"))
                } else {
                    showToast(L10n.t("图片发送失败，请重试", "Failed to send image"))
                }
            }
            return
        }
        if let text = board.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            Task {
                let ok = await handoffService.push(kind: "clipboard", title: L10n.t("剪贴板文本", "Clipboard"), url: nil, text: text, syncEngine: syncEngine)
                if ok {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    showToast(L10n.t("✅ 已发送剪贴板至电脑端", "✅ Clipboard sent to desktop"))
                } else {
                    showToast(L10n.t("发送失败", "Failed"))
                }
            }
            return
        }
        showToast(L10n.t("剪贴板为空，请先复制图片或文本", "Clipboard is empty"))
    }

    func refreshClipboardWebURLPatternSilently() {
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { [weak self] result in
            let isWebURL = (try? result.get().contains(.probableWebURL)) ?? false
            Task { @MainActor [weak self] in
                self?.hasClipboardWebURL = isWebURL
            }
        }
    }

    func checkClipboardForURL() {
        let board = UIPasteboard.general
        guard board.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = board.changeCount
        // Use privacy-safe detectPatterns first so copying ordinary text NEVER triggers iOS system paste banners
        board.detectPatterns(for: [.probableWebURL]) { [weak self] result in
            let isWebURL = (try? result.get().contains(.probableWebURL)) ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasClipboardWebURL = isWebURL
                guard isWebURL else { return }
                guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      text != self.lastPromptedClipboard,
                      text != self.activeTab?.urlString,
                      let url = self.extractHTTPURL(from: text) else { return }
                self.lastPromptedClipboard = text
                self.activeToast = ToastNotice(
                    message: L10n.t("检测到剪贴板链接：", "Clipboard URL detected: ") + (url.host ?? url.absoluteString),
                    actionTitle: L10n.t("立即打开", "Open"),
                    urlToOpen: url.absoluteString,
                    handoff: nil
                )
                let toastId = self.activeToast?.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if self?.activeToast?.id == toastId {
                        self?.activeToast = nil
                    }
                }
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

    private func topMostPresenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController else {
            return nil
        }
        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let tab = tabs.first(where: { $0.webView === webView })
        preferences.preferredContentMode = (tab?.isDesktopMode == true) ? .desktop : .mobile
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let policy = evaluateAppJumpShieldPolicy(for: url, in: webView, isMainFrame: isMain, isNewWindow: false)
        if policy == .cancel {
            decisionHandler(.cancel, preferences)
            return
        }
        if isMain {
            applyWebDarkAppearance(to: webView, url: url)
        }
        decisionHandler(policy, preferences)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        var didFinish = false
        let finish = {
            guard !didFinish else { return }
            didFinish = true
            completionHandler()
        }
        guard let presenter = topMostPresenter() else {
            finish()
            return
        }
        let host = frame.securityOrigin.host
        let title = host.isEmpty ? L10n.t("网页提示", "Page Alert") : host
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("好", "OK"), style: .default) { _ in
            finish()
        })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        var didFinish = false
        let finish: (Bool) -> Void = { confirmed in
            guard !didFinish else { return }
            didFinish = true
            completionHandler(confirmed)
        }
        guard let presenter = topMostPresenter() else {
            finish(false)
            return
        }
        let host = frame.securityOrigin.host
        let title = host.isEmpty ? L10n.t("确认操作", "Confirm") : host
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("取消", "Cancel"), style: .cancel) { _ in
            finish(false)
        })
        alert.addAction(UIAlertAction(title: L10n.t("确定", "OK"), style: .default) { _ in
            finish(true)
        })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        var didFinish = false
        let finish: (String?) -> Void = { value in
            guard !didFinish else { return }
            didFinish = true
            completionHandler(value)
        }
        guard let presenter = topMostPresenter() else {
            finish(nil)
            return
        }
        let host = frame.securityOrigin.host
        let title = host.isEmpty ? L10n.t("网页输入", "Prompt") : host
        let alert = UIAlertController(title: title, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
        }
        alert.addAction(UIAlertAction(title: L10n.t("取消", "Cancel"), style: .cancel) { _ in
            finish(nil)
        })
        alert.addAction(UIAlertAction(title: L10n.t("确定", "OK"), style: .default) { [weak alert] _ in
            finish(alert?.textFields?.first?.text)
        })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }
        let isNewWin = (navigationAction.targetFrame == nil)
        let policy = evaluateAppJumpShieldPolicy(
            for: url,
            in: webView,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            isNewWindow: isNewWin
        )
        if policy == .cancel {
            return nil
        }
        if isNewWin {
            createTab(url: url, profileId: tabs.first(where: { $0.webView === webView })?.profileId, activate: true)
        } else {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disp.contains("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleanName = suggestedFilename.isEmpty ? "download-\(Int(Date().timeIntervalSince1970))" : suggestedFilename
        var dest = dir.appendingPathComponent(cleanName)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            let stamped = ext.isEmpty ? "\(stem)-\(Int(Date().timeIntervalSince1970))" : "\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)"
            dest = dir.appendingPathComponent(stamped)
        }
        let dlKey = ObjectIdentifier(download)
        let sourceUrl = response.url?.absoluteString ?? ""
        let expectedLen = response.expectedContentLength
        Task { @MainActor [weak self] in
            guard let self else { return }
            let recId = UUID()
            self.downloadMap[dlKey] = recId
            self.downloads.insert(
                DownloadRecord(
                    id: recId,
                    filename: dest.lastPathComponent,
                    sourceURL: sourceUrl,
                    localURL: dest,
                    byteCount: expectedLen > 0 ? expectedLen : 0,
                    status: .downloading,
                    errorMessage: nil,
                    createdAt: Date()
                ),
                at: 0
            )
            self.showToast(L10n.t("开始下载：\(dest.lastPathComponent)", "Downloading: \(dest.lastPathComponent)"))
        }
        completionHandler(dest)
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        let dlKey = ObjectIdentifier(download)
        Task { @MainActor [weak self] in
            guard let self, let recId = self.downloadMap.removeValue(forKey: dlKey),
                  let idx = self.downloads.firstIndex(where: { $0.id == recId }) else { return }
            self.downloads[idx].status = .completed
            if let path = self.downloads[idx].localURL?.path,
               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? NSNumber {
                self.downloads[idx].byteCount = size.int64Value
            }
            self.showToast(L10n.t("下载完成：\(self.downloads[idx].filename)", "Downloaded: \(self.downloads[idx].filename)"))
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let dlKey = ObjectIdentifier(download)
        let errText = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let recId = self.downloadMap.removeValue(forKey: dlKey),
                  let idx = self.downloads.firstIndex(where: { $0.id == recId }) else { return }
            self.downloads[idx].status = .failed
            self.downloads[idx].errorMessage = errText
            self.showToast(L10n.t("下载失败：\(self.downloads[idx].filename)", "Download failed: \(self.downloads[idx].filename)"))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }) {
            tab.topBackdropColor = nil
        }
        applyWebDarkAppearance(to: webView, url: webView.url)
        syncWebViewState(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }) {
            tab.topBackdropColor = nil
        }
        applyWebDarkAppearance(to: webView, url: webView.url)
        let enabled = effectiveWebDarkEnabled(for: webView.url)
        let profile = (syncEngine?.profiles ?? [.defaultProfile]).first(where: { $0.id == tabs.first(where: { $0.webView === webView })?.profileId }) ?? .defaultProfile
        let jumpShieldOn = blockRogueAppJumps && profile.fingerprint.blockTrackers && !isHostAppJumpWhitelisted(webView.url)
        webView.evaluateJavaScript(
            "window.__prismSetWebDark && window.__prismSetWebDark(\(enabled ? "true" : "false")); window.__prismSampleTopColor && window.__prismSampleTopColor(true); window.__prismSetAppJumpShield && window.__prismSetAppJumpShield(\(jumpShieldOn ? "true" : "false"));",
            completionHandler: nil
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        applyWebDarkAppearance(to: webView, url: webView.url)
        let enabled = effectiveWebDarkEnabled(for: webView.url)
        var postLoadJS = "window.__prismSetWebDark && window.__prismSetWebDark(\(enabled ? "true" : "false")); window.__prismSampleTopColor && window.__prismSampleTopColor(true);"
        if let tab = tabs.first(where: { $0.webView === webView }),
           let pendingSeek = tab.pendingSeekSeconds,
           pendingSeek > 0 {
            postLoadJS += " window.__prismScheduleSeek && window.__prismScheduleSeek(\(pendingSeek));"
            tab.pendingSeekSeconds = nil
        }
        webView.evaluateJavaScript(postLoadJS, completionHandler: nil)
        syncWebViewState(webView)
        scheduleSessionSave()
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
            syncEngine.recordHistoryVisit(item)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        syncWebViewState(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        syncWebViewState(webView)
        let nsErr = error as NSError
        if (nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled)
            || (nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102) {
            return
        }
        let failingURL = (nsErr.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        if failingURL?.scheme?.lowercased() == "about" {
            return
        }
        let tab = tabs.first(where: { $0.webView === webView })
        let fallbackURLString = failingURL?.absoluteString ?? tab?.urlString ?? ""
        let escapedURL = htmlEscaped(fallbackURLString)
        let escapedReason = htmlEscaped(error.localizedDescription)
        let jsTargetJSON: String = {
            if let data = try? JSONEncoder().encode(fallbackURLString),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\"\""
        }()
        let isDark = isEffectiveAppDark
        let bgHex = isDark ? "#191A1C" : "#F5F6F8"
        let cardHex = isDark ? "#232529" : "#FFFFFF"
        let fgHex = isDark ? "#EAECEE" : "#1D1F23"
        let mutedHex = isDark ? "#9CA3AF" : "#6B7280"
        let accentHex = "#4B7BFF"
        let titleText = htmlEscaped(L10n.t("无法打开此网页", "Cannot Open Page"))
        let reloadText = htmlEscaped(L10n.t("重新加载", "Reload"))
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(titleText)</title>
        <style>
          :root { color-scheme: \(isDark ? "dark" : "light"); }
          html, body { margin: 0; padding: 0; background: \(bgHex); color: \(fgHex); font-family: -apple-system, BlinkMacSystemFont, sans-serif; height: 100%; }
          .wrap { min-height: 100%; display: flex; align-items: center; justify-content: center; padding: 24px; box-sizing: border-box; }
          .card { width: 100%; max-width: 420px; background: \(cardHex); border-radius: 22px; padding: 26px 22px; box-shadow: 0 14px 36px rgba(0,0,0,\(isDark ? "0.35" : "0.08")); text-align: center; }
          .icon { width: 48px; height: 48px; margin: 0 auto 14px; border-radius: 14px; background: rgba(75,123,255,0.14); color: \(accentHex); display: flex; align-items: center; justify-content: center; font-size: 24px; font-weight: 700; }
          h1 { font-size: 19px; margin: 0 0 8px; font-weight: 650; }
          .url { font-size: 12px; color: \(mutedHex); word-break: break-all; margin: 0 0 10px; }
          .reason { font-size: 13px; color: \(mutedHex); line-height: 1.5; margin: 0 0 20px; }
          button { width: 100%; border: 0; border-radius: 14px; padding: 13px 18px; font-size: 15px; font-weight: 600; background: \(accentHex); color: #fff; cursor: pointer; }
        </style>
        </head>
        <body>
          <div class="wrap">
            <div class="card">
              <div class="icon">!</div>
              <h1>\(titleText)</h1>
              <p class="url">\(escapedURL)</p>
              <p class="reason">\(escapedReason)</p>
              <button type="button" onclick="var u=\(jsTargetJSON); if(u){location.href=u;}else{location.reload();}">\(reloadText)</button>
            </div>
          </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: failingURL)
    }

    private func htmlEscaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.scrollView.refreshControl?.endRefreshing()
        guard let tab = tabs.first(where: { $0.webView === webView }), !tab.isNewTab else { return }
        if activeTabId == tab.id {
            tab.isLoading = true
            showToast(L10n.t("网页渲染进程已自动恢复", "Web page process recovered"))
            webView.reload()
        } else {
            // Never reload background tabs after Jetsam termination (prevents cascading OOM reload storm).
            // Hibernate cleanly preserving snapshot/title/url so switching back wakes lazily.
            tab.hibernate()
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
        if message.name == "prismTopColor" {
            guard let body = message.body as? [String: Any],
                  let r = body["r"] as? Double,
                  let g = body["g"] as? Double,
                  let b = body["b"] as? Double,
                  let webView = message.webView else { return }
            let color = UIColor(
                red: CGFloat(min(255, max(0, r))) / 255.0,
                green: CGFloat(min(255, max(0, g))) / 255.0,
                blue: CGFloat(min(255, max(0, b))) / 255.0,
                alpha: 1.0
            )
            applySampledTopColor(color, to: webView)
            return
        }

        guard message.name == "prismBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let payload = body["payload"] as? [String: Any] else { return }
        let webView = message.webView
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }

        switch type {
        case "userGesture":
            tab.markUserInteraction()
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
            if devToolsActive { tab.devToolsRevision += 1 }
        case "network":
            let method = (payload["method"] as? String) ?? "GET"
            let url = (payload["url"] as? String) ?? ""
            let status = (payload["status"] as? Int) ?? 0
            let duration = (payload["durationMs"] as? Int) ?? 0
            tab.networkLogs.insert(NetworkLogEntry(method: method, url: url, status: status, durationMs: duration), at: 0)
            if tab.networkLogs.count > 200 { tab.networkLogs.removeLast() }
            if devToolsActive { tab.devToolsRevision += 1 }
        case "videoState":
            let nextHasVideo = (payload["hasVideo"] as? Bool) ?? false
            let nextPaused = (payload["paused"] as? Bool) ?? true
            let nextRate = (payload["rate"] as? Double) ?? 1.0
            tab.videoSeconds = (payload["currentTime"] as? Double) ?? 0
            tab.videoDuration = (payload["duration"] as? Double) ?? 0
            if tab.hasVideo != nextHasVideo { tab.hasVideo = nextHasVideo }
            if tab.videoPaused != nextPaused { tab.videoPaused = nextPaused }
            if tab.playbackRate != nextRate { tab.playbackRate = nextRate }
            if nextHasVideo {
                if !nextPaused {
                    BackgroundMediaController.shared.activateAudioSessionIfNeeded()
                }
                if let pendingSeek = tab.pendingSeekSeconds, pendingSeek > 0 {
                    tab.pendingSeekSeconds = nil
                    webView?.evaluateJavaScript("window.__prismScheduleSeek && window.__prismScheduleSeek(\(pendingSeek));", completionHandler: nil)
                }
                let host = URL(string: tab.urlString)?.host ?? "Prism"
                BackgroundMediaController.shared.updateNowPlaying(
                    title: tab.title,
                    host: host,
                    duration: tab.videoDuration,
                    elapsed: tab.videoSeconds,
                    playing: !nextPaused
                )
            }
        case "passwordFocus":
            guard let trusted = trustedOrigin(from: message), let syncEngine else { return }
            let matches = syncEngine.passwords.filter { entry in
                let storedHost = (URL(string: entry.origin)?.host ?? entry.origin).lowercased()
                return storedHost == trusted.host
                    || trusted.host.hasSuffix(".\(storedHost)")
                    || storedHost.hasSuffix(".\(trusted.host)")
            }
            tab.matchedPasswords = matches
            let shouldShow = !matches.isEmpty
            if tab.showAutofillBar != shouldShow {
                // Slight delay ensures WKContentView finishes first-responder keyboard presentation uninterrupted
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak tab] in
                    guard let tab else { return }
                    if tab.showAutofillBar != !tab.matchedPasswords.isEmpty {
                        tab.showAutofillBar = !tab.matchedPasswords.isEmpty
                    }
                }
            }
        case "passwordCapture":
            guard let trusted = trustedOrigin(from: message),
                  let password = payload["password"] as? String,
                  !password.isEmpty else { return }
            let username = (payload["username"] as? String) ?? ""
            tab.pendingPasswordSave = (origin: trusted.origin, username: username, password: password)
        default:
            break
        }
    }

    private func trustedOrigin(from message: WKScriptMessage) -> (origin: String, host: String)? {
        let sec = message.frameInfo.securityOrigin
        let scheme = sec.protocol.lowercased()
        let host = sec.host.lowercased()
        guard (scheme == "http" || scheme == "https"), !host.isEmpty else {
            return nil
        }
        let defaultPort = (scheme == "https" ? 443 : 80)
        let framePort = sec.port != 0 ? sec.port : defaultPort

        if !message.frameInfo.isMainFrame {
            guard let mainURL = message.webView?.url,
                  let mainScheme = mainURL.scheme?.lowercased(),
                  let mainHost = mainURL.host?.lowercased() else {
                return nil
            }
            let mainDefaultPort = (mainScheme == "https" ? 443 : 80)
            let mainPort = mainURL.port ?? mainDefaultPort
            guard mainScheme == scheme && mainHost == host && mainPort == framePort else {
                return nil
            }
        }

        let canonicalOrigin = (sec.port != 0 && sec.port != defaultPort)
            ? "\(scheme)://\(host):\(sec.port)"
            : "\(scheme)://\(host)"
        return (canonicalOrigin, host)
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
        themeMode: String,
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
        let followBool = followThemeDark ? "true" : "false"

        return """
        (function() {
          if (window.__prismWebDarkStartInstalled) return;
          window.__prismWebDarkStartInstalled = true;

          window.__prismThemeMode = "\(themeMode)";
          window.__prismFollowDark = \(followBool);
          window.__prismWhitelist = new Set(\(whitelistJSON));

          const computeEnabledNow = () => {
            const host = (location.hostname || '').toLowerCase();
            const isHttp = location.protocol === 'http:' || location.protocol === 'https:';
            if (!window.__prismFollowDark) return false;
            if (isHttp && window.__prismWhitelist.has(host)) return false;
            if (window.__prismThemeMode === 'dark') return true;
            if (window.__prismThemeMode === 'light') return false;
            return Boolean(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
          };

          window.__prismComputeWebDarkEnabled = computeEnabledNow;
          window.__prismWebDarkEnabled = computeEnabledNow();

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
              html[data-prism-dark="1"] iframe {
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

          if (window.__prismWebDarkEnabled && document.documentElement) {
            ensureColorSchemeMeta(true);
            ensureDarkStyle();
            // Lock Pre-Paint dark mode immediately at documentStart BEFORE first body paint (0ms no white flash)
            document.documentElement.setAttribute('data-prism-dark', '1');
          }

          window.__prismWebDarkEnsure = {
            ensureColorSchemeMeta,
            ensureDarkStyle
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
            ensureDarkStyle: function() {}
          };

          let isApplyingInternal = false;
          const observedPendingLinks = new WeakSet();

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
            if (a <= 0.15) return null;
            const luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
            return { r, g, b, a, luminance };
          }

          function resolveCssColorString(colorStr) {
            if (!colorStr) return null;
            const direct = parseCssRgb(colorStr);
            if (direct) return direct;
            const root = document.body || document.documentElement;
            if (!root) return null;
            const probe = document.createElement('div');
            probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;background-color:' + colorStr + ';';
            root.appendChild(probe);
            const computed = getComputedStyle(probe).backgroundColor;
            probe.remove();
            return parseCssRgb(computed);
          }

          function compensateDarkFilter(rgb) {
            const inv = (v) => {
              const n = Math.min(1, Math.max(0, v / 255));
              return n * 0.08 + (1 - n) * 0.92;
            };
            const r1 = inv(rgb.r);
            const g1 = inv(rgb.g);
            const b1 = inv(rgb.b);
            const r2 = -0.574 * r1 + 1.430 * g1 + 0.144 * b1;
            const g2 =  0.426 * r1 + 0.430 * g1 + 0.144 * b1;
            const b2 =  0.426 * r1 + 1.430 * g1 - 0.856 * b1;
            const ctr = (v) => Math.max(0, Math.min(255, Math.round(((v - 0.5) * 0.96 + 0.5) * 255)));
            return { r: ctr(r2), g: ctr(g2), b: ctr(b2) };
          }

          function isDarkSchemeActive() {
            if (window.__prismThemeMode === 'dark') return true;
            if (window.__prismThemeMode === 'light') return false;
            return Boolean(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
          }

          function hasPendingStylesheets() {
            let pending = false;
            const links = document.querySelectorAll('link[rel~="stylesheet"]');
            for (let i = 0; i < links.length; i += 1) {
              const ln = links[i];
              if (!ln.disabled && !ln.sheet) {
                pending = true;
                if (!observedPendingLinks.has(ln)) {
                  observedPendingLinks.add(ln);
                  ln.addEventListener('load', () => evaluateAndApply(true, true), { once: true });
                  ln.addEventListener('error', () => evaluateAndApply(false, true), { once: true });
                }
              }
            }
            return pending;
          }

          function isAlreadyDarkPage() {
            const root = document.documentElement;
            if (!root) return false;

            isApplyingInternal = true;
            const prevAttr = root.getAttribute('data-prism-dark');
            if (prevAttr === '1') {
              root.removeAttribute('data-prism-dark');
            }
            // Temporarily detach Prism's own injected meta[data-prism-cs="1"] so we never spoof our own colorScheme detection!
            const ownMeta = document.querySelector('meta[data-prism-cs="1"]');
            const ownMetaParent = ownMeta ? ownMeta.parentNode : null;
            const ownMetaNext = ownMeta ? ownMeta.nextSibling : null;
            if (ownMeta && ownMetaParent) {
              ownMeta.remove();
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

              // Transparent background while external CSS is still downloading -> keep dark invert locked!
              if (hasPendingStylesheets()) return false;

              const nativeMeta = document.querySelector('meta[name="color-scheme"]:not([data-prism-cs])');
              const metaCS = nativeMeta ? (nativeMeta.getAttribute('content') || '').toLowerCase() : '';
              const rootCS = (getComputedStyle(root).colorScheme || '').toLowerCase();
              return metaCS.includes('dark') || rootCS.includes('dark');
            } finally {
              if (ownMeta && ownMetaParent && !document.querySelector('meta[data-prism-cs="1"]')) {
                ownMetaParent.insertBefore(ownMeta, ownMetaNext);
              }
              if (prevAttr === '1' && window.__prismWebDarkEnabled) {
                root.setAttribute('data-prism-dark', '1');
              }
              isApplyingInternal = false;
            }
          }

          let lastPostedTopKey = '';
          function sampleAndPostTopColor(forcePost) {
            try {
              const root = document.documentElement;
              const filterActive = Boolean(root && root.getAttribute('data-prism-dark') === '1');
              let sampled = null;

              const metas = document.querySelectorAll('meta[name="theme-color"]');
              for (let i = 0; i < metas.length; i += 1) {
                const m = metas[i];
                const media = (m.getAttribute('media') || '').trim();
                if (media && window.matchMedia && !window.matchMedia(media).matches) {
                  continue;
                }
                const c = resolveCssColorString((m.getAttribute('content') || '').trim());
                if (c) {
                  sampled = c;
                  break;
                }
              }

              if (!sampled && typeof document.elementFromPoint === 'function' && window.innerWidth > 10) {
                const sx = Math.max(0, Math.floor(window.innerWidth / 2));
                const probeY = [2, 12];
                for (let p = 0; p < probeY.length && !sampled; p += 1) {
                  let el = document.elementFromPoint(sx, probeY[p]);
                  while (el) {
                    const c = parseCssRgb(getComputedStyle(el).backgroundColor);
                    if (c) {
                      sampled = c;
                      break;
                    }
                    el = el.parentElement;
                  }
                }
              }

              if (!sampled && document.body) {
                sampled = parseCssRgb(getComputedStyle(document.body).backgroundColor);
              }
              if (!sampled && root) {
                sampled = parseCssRgb(getComputedStyle(root).backgroundColor);
              }

              if (sampled && filterActive) {
                sampled = compensateDarkFilter(sampled);
              }

              if (!sampled) {
                if (filterActive) {
                  sampled = { r: 25, g: 26, b: 28 };
                } else if (isDarkSchemeActive()) {
                  sampled = { r: 25, g: 26, b: 28 };
                } else {
                  sampled = { r: 255, g: 255, b: 255 };
                }
              }

              const outR = Math.round(sampled.r);
              const outG = Math.round(sampled.g);
              const outB = Math.round(sampled.b);
              const key = outR + ',' + outG + ',' + outB;
              if (!forcePost && key === lastPostedTopKey) return;
              lastPostedTopKey = key;
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.prismTopColor) {
                window.webkit.messageHandlers.prismTopColor.postMessage({ r: outR, g: outG, b: outB });
              }
            } catch (e) {}
          }

          window.__prismSampleTopColor = function(forcePost) {
            sampleAndPostTopColor(Boolean(forcePost));
          };

          let cachedNativeDark = null;
          let lastEvaluatedUrl = '';

          function evaluateAndApply(forceTopColor, forceRecheck) {
            const root = document.documentElement;
            if (!root) return;

            const currentUrl = location.href;
            if (currentUrl !== lastEvaluatedUrl) {
              cachedNativeDark = null;
              lastEvaluatedUrl = currentUrl;
            }

            isApplyingInternal = true;
            try {
              if (!window.__prismWebDarkEnabled) {
                helper.ensureColorSchemeMeta(false);
                root.removeAttribute('data-prism-dark');
                sampleAndPostTopColor(Boolean(forceTopColor));
                return;
              }

              helper.ensureColorSchemeMeta(true);
              helper.ensureDarkStyle();
              let isDarkNative;
              if (!forceRecheck && cachedNativeDark !== null) {
                isDarkNative = cachedNativeDark;
              } else {
                isDarkNative = isAlreadyDarkPage();
                if (!hasPendingStylesheets()) {
                  cachedNativeDark = isDarkNative;
                }
              }
              root.setAttribute('data-prism-dark', isDarkNative ? '0' : '1');
              sampleAndPostTopColor(Boolean(forceTopColor));
            } finally {
              isApplyingInternal = false;
            }
          }

          window.__prismSyncConfig = function(themeMode, followDark, whitelistArr) {
            window.__prismThemeMode = themeMode || 'system';
            window.__prismFollowDark = Boolean(followDark);
            window.__prismWhitelist = new Set(Array.isArray(whitelistArr) ? whitelistArr : []);
          };

          window.__prismSetWebDark = function(enabled) {
            window.__prismWebDarkEnabled = Boolean(enabled);
            cachedNativeDark = null;
            evaluateAndApply(true, true);
          };

          window.__prismOnTraitChanged = function() {
            if (typeof window.__prismComputeWebDarkEnabled === 'function') {
              window.__prismWebDarkEnabled = window.__prismComputeWebDarkEnabled();
            }
            cachedNativeDark = null;
            evaluateAndApply(true, true);
            if (typeof requestAnimationFrame === 'function') {
              requestAnimationFrame(() => evaluateAndApply(true, true));
            }
          };

          // Full lifecycle healing: DOMContentLoaded + window.load + pageshow (BFCache back/forward)
          evaluateAndApply(true, true);
          if (typeof requestAnimationFrame === 'function') {
            requestAnimationFrame(() => evaluateAndApply(true, false));
          }
          setTimeout(() => evaluateAndApply(false, cachedNativeDark === null), 350);

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', () => evaluateAndApply(true, true), { once: true });
          }
          window.addEventListener('load', () => {
            cachedNativeDark = null;
            evaluateAndApply(true, true);
          });
          window.addEventListener('pageshow', () => {
            if (typeof window.__prismComputeWebDarkEnabled === 'function') {
              window.__prismWebDarkEnabled = window.__prismComputeWebDarkEnabled();
            }
            cachedNativeDark = null;
            evaluateAndApply(true, true);
          });

          if (window.matchMedia) {
            const darkMQ = window.matchMedia('(prefers-color-scheme: dark)');
            const onMediaChange = () => window.__prismOnTraitChanged();
            if (typeof darkMQ.addEventListener === 'function') {
              darkMQ.addEventListener('change', onMediaChange);
            } else if (typeof darkMQ.addListener === 'function') {
              darkMQ.addListener(onMediaChange);
            }
          }

          let rafScheduled = false;
          const scheduleHealingPass = (forceRecheck) => {
            if (isApplyingInternal || rafScheduled) return;
            rafScheduled = true;
            const runPass = () => {
              rafScheduled = false;
              evaluateAndApply(false, Boolean(forceRecheck));
            };
            if (typeof requestAnimationFrame === 'function') {
              requestAnimationFrame(runPass);
            } else {
              setTimeout(runPass, 16);
            }
          };

          // Self-healing MutationObserver guarding head + documentElement with O(1) fast-path short-circuit
          if (typeof MutationObserver === 'function') {
            const mo = new MutationObserver(() => {
              if (isApplyingInternal) return;
              const root = document.documentElement;
              const urlChanged = location.href !== lastEvaluatedUrl;
              if (window.__prismWebDarkEnabled) {
                const styleMissing = !document.getElementById('prism-dark-style');
                const attrMissing = Boolean(root && !root.hasAttribute('data-prism-dark'));
                if (styleMissing || attrMissing) {
                  scheduleHealingPass(urlChanged || cachedNativeDark === null);
                  return;
                }
                if (!urlChanged && cachedNativeDark !== null) {
                  // O(1) fast-path: dark style & attribute intact on same URL, skip forced reflow!
                  return;
                }
              } else if (!urlChanged && root && !root.hasAttribute('data-prism-dark')) {
                return;
              }
              scheduleHealingPass(urlChanged || cachedNativeDark === null);
            });
            if (document.head) {
              mo.observe(document.head, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['content', 'media', 'rel', 'disabled']
              });
            }
            if (document.documentElement) {
              mo.observe(document.documentElement, {
                childList: true,
                attributes: true,
                attributeFilter: ['class', 'style', 'data-prism-dark']
              });
            }
          }
        })();
        """
    }
}
