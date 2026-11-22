import Combine
import SwiftUI
import UIKit
import WebKit

struct BrowserRootView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    @ObservedObject var handoffService: HandoffService

    @State private var showOmniboxEditor = false
    @State private var omniboxInput = ""
    @State private var showTabSwitcher = false
    @State private var activeSheet: ActiveSheet?

    @State private var isSpeed2x = false
    @State private var scrubOffsetSec: Double = 0
    @State private var isScrubbingVideo = false
    @State private var topCapsuleToast: ToastNotice?
    @State private var topToastDismissTask: Task<Void, Never>?

    enum ActiveSheet: Identifiable {
        case menu, account, profiles, vault, sniffer, devtools
        var id: Self { self }
    }

    var body: some View {
        let currentTab = tabManager.activeTab
        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                if let tab = currentTab {
                    if tab.isNewTab {
                        HomeNewTabView(syncEngine: syncEngine, tabManager: tabManager)
                    } else {
                        WebViewRepresentable(tab: tab, tabManager: tabManager)
                            .ignoresSafeArea(.container, edges: [.top, .bottom])
                            .transaction { $0.animation = nil }

                        // Right-edge Long Press 2.0x Gesture Strip (unobtrusive 28pt edge)
                        if tab.hasVideo {
                            HStack {
                                Spacer()
                                Color.clear
                                    .frame(width: 44)
                                    .contentShape(Rectangle())
                                    .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                            isSpeed2x = pressing
                                        }
                                        let rate = pressing ? 2.0 : 1.0
                                        tab.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('rate', \(rate));", completionHandler: nil)
                                    }, perform: {})
                            }
                        }
                    }
                }

                // Slim Loading Bar
                if let tab = currentTab, tab.isLoading && !tab.isNewTab {
                    ProgressView(value: tab.estimatedProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                }

                // 2.0x Pill Indicator
                if isSpeed2x {
                    VStack {
                        HStack(spacing: 6) {
                            Image(systemName: "forward.fill")
                            Text(L10n.t("2.0x 倍速播放中", "2.0x Speed"))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(.top, 16)
                        Spacer()
                    }
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                }

                // Horizontal scrub feedback pill
                if isScrubbingVideo {
                    Text(String(format: "%+.0fs", scrubOffsetSec))
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.75), in: Capsule())
                        .frame(maxHeight: .infinity)
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }

            // Floating Overlays Above Bottom Thumb Bar
            VStack(spacing: 8) {
                if let handoff = handoffService.latestIncoming {
                    HandoffBannerView(payload: handoff) {
                        if let raw = handoff.url, let url = URL(string: raw) {
                            let seek = (handoff.videoSeconds ?? 0) > 0 ? handoff.videoSeconds : nil
                            tabManager.createTab(url: url, activate: true, seekSeconds: seek)
                        } else if let text = handoff.text {
                            UIPasteboard.general.string = text
                            tabManager.syncClipboardChangeCount()
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showTopCapsuleToast(L10n.t("📋 已同步来自电脑的剪贴板", "📋 Synced clipboard from desktop"))
                        }
                        handoffService.latestIncoming = nil
                    } onDismiss: {
                        handoffService.latestIncoming = nil
                    }
                }

                if let toast = tabManager.activeToast {
                    ToastBannerView(toast: toast) {
                        if let raw = toast.urlToOpen, let url = URL(string: raw) {
                            tabManager.createTab(url: url, activate: true)
                        }
                        tabManager.activeToast = nil
                    } onDismiss: {
                        tabManager.activeToast = nil
                    }
                }

                if let tab = currentTab, let blockedUrl = tab.blockedAppJumpURL {
                    BlockedAppJumpBanner(url: blockedUrl) {
                        tabManager.allowOnceAppJump(blockedUrl)
                    } onDismiss: {
                        tab.blockedAppJumpURL = nil
                    }
                }

                if let tab = currentTab, let pending = tab.pendingPasswordSave {
                    SavePasswordBanner(initialUsername: pending.username) { editedUser in
                        tabManager.savePendingPassword(usernameOverride: editedUser)
                    } onDismiss: {
                        tab.pendingPasswordSave = nil
                    }
                }

                if let tab = currentTab, tab.showAutofillBar, let firstCred = tab.matchedPasswords.first {
                    AutofillBar(entries: tab.matchedPasswords, primary: firstCred) { chosen in
                        tabManager.autofillWithFaceID(entry: chosen)
                    } onDismiss: {
                        tab.showAutofillBar = false
                    }
                }

                // Video Quick Control Strip (Desktop Handoff only; PiP & Speed moved into More menu)
                if let tab = currentTab, tab.hasVideo && !tab.isNewTab {
                    VideoMiniStrip(tab: tab, handoffService: handoffService, syncEngine: syncEngine, tabManager: tabManager) {
                        activeSheet = .account
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Single-Hand 52pt Bottom Thumb Dock
                BottomThumbDock(
                    syncEngine: syncEngine,
                    tabManager: tabManager,
                    onTapOmnibox: {
                        omniboxInput = (currentTab?.isNewTab == true) ? "" : (currentTab?.urlString ?? "")
                        showOmniboxEditor = true
                    },
                    onOpenTabs: { showTabSwitcher = true },
                    onOpenProfiles: { activeSheet = .profiles },
                    onOpenMenu: { activeSheet = .menu },
                    onHorizontalScrub: { deltaX, ended in
                        if tabManager.activeTab?.hasVideo == true && !(tabManager.activeTab?.isNewTab ?? true) {
                            if !ended {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                                    isScrubbingVideo = true
                                }
                                scrubOffsetSec = Double(deltaX / 8.0)
                            } else {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    isScrubbingVideo = false
                                }
                                let sec = scrubOffsetSec
                                tabManager.activeTab?.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('seekBy', \(sec));", completionHandler: nil)
                            }
                        } else if ended {
                            if deltaX < -55 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    tabManager.switchTab(byOffset: 1)
                                }
                            } else if deltaX > 55 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    tabManager.switchTab(byOffset: -1)
                                }
                            }
                        }
                    },
                    onPullUpTabs: {
                        showTabSwitcher = true
                    }
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: currentTab?.hasVideo)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: handoffService.latestIncoming != nil)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: tabManager.activeToast?.id)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: currentTab?.showAutofillBar)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: currentTab?.pendingPasswordSave != nil)

            // Top Capsule Toast Overlay for Instant Handoff & Clipboard Sync
            VStack {
                if let toast = topCapsuleToast {
                    TopCapsuleToastView(toast: toast) {
                        if let raw = toast.urlToOpen, let url = URL(string: raw) {
                            tabManager.createTab(url: url, activate: true)
                        }
                        topToastDismissTask?.cancel()
                        withAnimation(.easeOut(duration: 0.2)) {
                            topCapsuleToast = nil
                        }
                    } onDismiss: {
                        topToastDismissTask?.cancel()
                        withAnimation(.easeOut(duration: 0.2)) {
                            topCapsuleToast = nil
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 10)
            .padding(.horizontal, 16)
            .allowsHitTesting(topCapsuleToast != nil)
        }
        .onAppear {
            handleIncomingHandoff(handoffService.latestIncoming)
        }
        .onChange(of: handoffService.latestIncoming) { _, incoming in
            handleIncomingHandoff(incoming)
        }
        .sheet(isPresented: $showOmniboxEditor) {
            OmniboxEditorSheet(
                text: $omniboxInput,
                bookmarks: syncEngine.bookmarks,
                history: syncEngine.history,
                tabs: tabManager.tabs,
                activeTabId: tabManager.activeTabId,
                shortcuts: syncEngine.homeConfig.shortcuts,
                searchEngine: tabManager.searchEngine,
                canFindInPage: !(currentTab?.isNewTab ?? true),
                onSubmit: { target in
                    tabManager.navigateActive(target)
                    showOmniboxEditor = false
                },
                onSelectTab: { tabId in
                    tabManager.activateTab(id: tabId)
                    showOmniboxEditor = false
                },
                onFindInPage: { query in
                    showOmniboxEditor = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        tabManager.findInActivePage(query)
                    }
                }
            )
        }
        .sheet(isPresented: $showTabSwitcher) {
            TabSwitcherView(tabManager: tabManager, syncEngine: syncEngine)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .menu:
                MenuSheetView(syncEngine: syncEngine, tabManager: tabManager, handoffService: handoffService) { target in
                    activeSheet = target
                }
            case .account:
                AccountSheetView(syncEngine: syncEngine)
            case .profiles:
                ProfilesSheetView(syncEngine: syncEngine, tabManager: tabManager)
            case .vault:
                VaultSheetView(syncEngine: syncEngine)
            case .sniffer:
                SnifferSheetView(tab: tabManager.activeTab)
            case .devtools:
                MobileDevToolsSheetView(tab: tabManager.activeTab, syncEngine: syncEngine, handoffService: handoffService, tabManager: tabManager)
            }
        }
        .preferredColorScheme(
            tabManager.appTheme == .dark ? .dark : (tabManager.appTheme == .light ? .light : nil)
        )
    }

    private func showTopCapsuleToast(_ message: String, actionTitle: String? = nil, urlToOpen: String? = nil) {
        let notice = ToastNotice(message: message, actionTitle: actionTitle, urlToOpen: urlToOpen, handoff: nil)
        topToastDismissTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            topCapsuleToast = notice
        }
        topToastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            if topCapsuleToast?.id == notice.id {
                withAnimation(.easeOut(duration: 0.25)) {
                    topCapsuleToast = nil
                }
            }
        }
    }

    private func handleIncomingHandoff(_ payload: HandoffPayload?) {
        guard let payload else { return }
        let kind = payload.kind.lowercased()
        if kind == "clipboard" {
            let text = payload.text ?? ""
            if !text.isEmpty {
                UIPasteboard.general.string = text
                tabManager.syncClipboardChangeCount()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let validUrl = tabManager.extractHTTPURL(from: text)?.absoluteString
                showTopCapsuleToast(
                    L10n.t("📋 已同步来自电脑的剪贴板", "📋 Synced clipboard from desktop"),
                    actionTitle: validUrl != nil ? L10n.t("直接打开", "Open") : nil,
                    urlToOpen: validUrl
                )
            }
            handoffService.latestIncoming = nil
            return
        }

        if kind == "tab" || kind == "video" {
            let ageMs = Date().timeIntervalSince1970 * 1000 - payload.createdAt
            if ageMs <= 90_000, let raw = payload.url, let url = URL(string: raw) {
                let seek = (payload.videoSeconds ?? 0) > 0 ? payload.videoSeconds : nil
                tabManager.createTab(url: url, activate: true, seekSeconds: seek)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showTopCapsuleToast(L10n.t("💻 已接力打开来自电脑的网页", "💻 Opened webpage from desktop"))
                handoffService.latestIncoming = nil
            }
        }
    }
}

private struct BottomThumbDock: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    let onTapOmnibox: () -> Void
    let onOpenTabs: () -> Void
    let onOpenProfiles: () -> Void
    let onOpenMenu: () -> Void
    let onHorizontalScrub: (CGFloat, Bool) -> Void
    let onPullUpTabs: () -> Void

    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        let activeTab = tabManager.activeTab
        let profile = tabManager.activeProfile

        HStack(spacing: 8) {
            // Quick Back
            Button {
                activeTab?.webView?.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 36)
            }
            .disabled(!(activeTab?.canGoBack ?? false))

            // Profile Color Pill
            Button(action: onOpenProfiles) {
                Circle()
                    .fill(profile.swiftColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 28, height: 36)
            }

            // Central Interactive Omnibox Pill (Tap to edit, Swipe L/R switch tab, Swipe Up tab grid)
            Button(action: onTapOmnibox) {
                HStack(spacing: 6) {
                    if let tab = activeTab, !tab.isNewTab, tab.urlString.hasPrefix("https://") {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Text(displayOmniboxLabel(activeTab))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let tab = activeTab, !tab.isNewTab {
                        Button {
                            tab.webView?.reload()
                        } label: {
                            Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { val in
                        if abs(val.translation.width) > abs(val.translation.height) {
                            onHorizontalScrub(val.translation.width, false)
                        }
                    }
                    .onEnded { val in
                        if val.translation.height < -45 && abs(val.translation.height) > abs(val.translation.width) {
                            onPullUpTabs()
                        } else if abs(val.translation.width) > abs(val.translation.height) {
                            onHorizontalScrub(val.translation.width, true)
                        }
                    }
            )

            // Tab Count Badge
            Button(action: onOpenTabs) {
                Text("\(tabManager.tabs.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary, lineWidth: 1.5)
                    )
                    .frame(width: 32, height: 36)
            }

            // More Sheet
            Button(action: onOpenMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 36)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 12, x: 0, y: 4)
    }

    private func displayOmniboxLabel(_ tab: BrowserTab?) -> String {
        guard let tab, !tab.isNewTab else {
            return L10n.t("搜索或输入网址", "Search or enter URL")
        }
        if let host = URL(string: tab.urlString)?.host, !host.isEmpty {
            return host
        }
        return tab.title
    }
}

@MainActor
final class PrismWebContainerView: UIView, PrismTopColorHost {
    let topSafeAreaBackdropView = UIView()
    weak var tabManager: TabManager?
    private(set) weak var hostedWebView: WKWebView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TabManager.dynamicSystemBackdropColor
        topSafeAreaBackdropView.translatesAutoresizingMaskIntoConstraints = false
        topSafeAreaBackdropView.backgroundColor = TabManager.dynamicSystemBackdropColor
        addSubview(topSafeAreaBackdropView)
        NSLayoutConstraint.activate([
            topSafeAreaBackdropView.topAnchor.constraint(equalTo: topAnchor),
            topSafeAreaBackdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSafeAreaBackdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSafeAreaBackdropView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attachWebView(_ webView: WKWebView, tabManager: TabManager, targetURL: URL?) {
        self.tabManager = tabManager
        if hostedWebView !== webView {
            hostedWebView?.removeFromSuperview()
            hostedWebView = webView
            webView.translatesAutoresizingMaskIntoConstraints = false
            insertSubview(webView, belowSubview: topSafeAreaBackdropView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        tabManager.applyWebDarkAppearance(to: webView, url: targetURL, trait: traitCollection)
    }

    func applyTopColor(_ color: UIColor, from traitCollection: UITraitCollection?) {
        let tc = traitCollection ?? self.traitCollection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let resolved = color.resolvedColor(with: tc)
        topSafeAreaBackdropView.backgroundColor = resolved
        backgroundColor = resolved
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard UIApplication.shared.applicationState != .background else { return }
        if let ws = window?.windowScene, ws.activationState == .background { return }
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        tabManager?.handleNativeTraitAppearanceChange(
            isDarkNow: traitCollection.userInterfaceStyle == .dark,
            webView: hostedWebView,
            trait: traitCollection
        )
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var tabManager: TabManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PrismWebContainerView {
        let container = PrismWebContainerView(frame: .zero)
        let wv = tabManager.ensureWebView(for: tab)
        container.attachWebView(wv, tabManager: tabManager, targetURL: wv.url ?? URL(string: tab.urlString))
        attachRefreshControl(to: wv, coordinator: context.coordinator)
        return container
    }

    func updateUIView(_ uiView: PrismWebContainerView, context: Context) {
        let target = tabManager.ensureWebView(for: tab)
        uiView.attachWebView(target, tabManager: tabManager, targetURL: target.url ?? URL(string: tab.urlString))
        attachRefreshControl(to: target, coordinator: context.coordinator)
    }

    private func attachRefreshControl(to webView: WKWebView, coordinator: Coordinator) {
        coordinator.webView = webView
        webView.scrollView.bounces = true
        if webView.scrollView.refreshControl == nil {
            let rc = UIRefreshControl()
            rc.addTarget(coordinator, action: #selector(Coordinator.handlePullToRefresh(_:)), for: .valueChanged)
            webView.scrollView.refreshControl = rc
        }
    }

    final class Coordinator: NSObject {
        weak var webView: WKWebView?

        @objc func handlePullToRefresh(_ sender: UIRefreshControl) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                if sender.isRefreshing {
                    sender.endRefreshing()
                }
            }
        }
    }
}

@MainActor
private final class OmniboxRemoteSuggester: ObservableObject {
    @Published var suggestions: [String] = []
    private var fetchTask: Task<Void, Never>?
    private var lastQuery = ""

    func update(query: String, engine: SearchEngineOption) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.hasPrefix("localhost"),
              !trimmed.hasPrefix("127.0.0.1") else {
            fetchTask?.cancel()
            lastQuery = ""
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        if trimmed == lastQuery { return }
        lastQuery = trimmed
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 110_000_000)
            guard !Task.isCancelled else { return }
            let items = await Self.fetchRemote(query: trimmed, engine: engine)
            guard !Task.isCancelled else { return }
            self?.suggestions = items
        }
    }

    private static func fetchRemote(query: String, engine: SearchEngineOption) async -> [String] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let endpointStr: String
        switch engine {
        case .bing:
            endpointStr = "https://api.bing.com/osjson.aspx?query=\(encoded)"
        case .duckduckgo:
            endpointStr = "https://duckduckgo.com/ac/?q=\(encoded)"
        case .baidu:
            endpointStr = "https://suggestion.baidu.com/su?wd=\(encoded)&action=opensearch"
        case .google:
            endpointStr = "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)"
        }
        guard let url = URL(string: endpointStr) else { return [] }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            if engine == .duckduckgo {
                if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    return arr.compactMap { ($0["phrase"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                return []
            }
            let parsedObj: Any?
            if let direct = try? JSONSerialization.jsonObject(with: data) {
                parsedObj = direct
            } else if engine == .baidu {
                let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
                if let gbkStr = String(data: data, encoding: String.Encoding(rawValue: cfEnc)),
                   let utf8Data = gbkStr.data(using: .utf8) {
                    parsedObj = try? JSONSerialization.jsonObject(with: utf8Data)
                } else {
                    parsedObj = nil
                }
            } else {
                parsedObj = nil
            }
            if let root = parsedObj as? [Any], root.count > 1, let list = root[1] as? [String] {
                return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        } catch {
            return []
        }
        return []
    }
}

private struct OmniboxCandidateEntry: Identifiable {
    let id: String
    let title: String
    let url: String
    let subtitle: String
    let isBookmark: Bool
    let tabId: UUID?
    let score: Int
    let visitedAt: Double
}

private struct OmniboxEditorSheet: View {
    @Binding var text: String
    let bookmarks: [BookmarkItem]
    let history: [HistoryItem]
    let tabs: [BrowserTab]
    let activeTabId: UUID?
    let shortcuts: [HomeShortcut]
    let searchEngine: SearchEngineOption
    let canFindInPage: Bool
    let onSubmit: (String) -> Void
    let onSelectTab: (UUID) -> Void
    let onFindInPage: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var remoteSuggester = OmniboxRemoteSuggester()

    var body: some View {
        buildBody()
    }

    private func buildBody() -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = trimmed.lowercased()
        let tokens = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let ranked = buildLocalCandidates(queryLower: q, tokens: tokens)
        let topHit = !q.isEmpty ? ranked.topHit : nil
        let matchedTabs = ranked.tabs
        let libraryItems = ranked.library
        let remoteList = buildRemoteSearchList(trimmed: trimmed, rawLower: q, remote: remoteSuggester.suggestions)

        return NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    SelectableAddressBar(
                        text: $text,
                        placeholder: L10n.t("输入网址或搜索词", "Search or type a URL"),
                        onSubmit: { target in
                            onSubmit(target)
                        },
                        onPasteAndGo: { target in
                            onSubmit(target)
                        }
                    )
                    .frame(height: 24)
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)

                List {
                    if let hit = topHit {
                        Section {
                            Button {
                                if let tid = hit.tabId {
                                    onSelectTab(tid)
                                } else {
                                    onSubmit(hit.url)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.indigo.opacity(0.14))
                                            .frame(width: 32, height: 32)
                                        Image(systemName: hit.tabId != nil ? "macwindow" : (hit.isBookmark ? "bookmark.fill" : "globe"))
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.indigo)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.title)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(hit.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(L10n.t("最佳匹配", "Top Hit"))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.indigo)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.indigo.opacity(0.12), in: Capsule())
                                }
                            }
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                        }
                    }

                    if !matchedTabs.isEmpty {
                        Section(q.isEmpty ? L10n.t("打开的标签页", "Open Tabs") : "") {
                            ForEach(matchedTabs) { item in
                                Button {
                                    if let tid = item.tabId {
                                        onSelectTab(tid)
                                    } else {
                                        onSubmit(item.url)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color(.tertiarySystemFill))
                                                .frame(width: 30, height: 30)
                                            Image(systemName: "macwindow")
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(item.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !remoteList.isEmpty {
                        Section("\(searchEngine.title)\(L10n.t(" 建议", " Suggestions"))") {
                            ForEach(remoteList, id: \.self) { term in
                                HStack(spacing: 10) {
                                    Button {
                                        onSubmit(term)
                                    } label: {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(Color(.tertiarySystemFill))
                                                    .frame(width: 30, height: 30)
                                                Image(systemName: "magnifyingglass")
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(.secondary)
                                            }
                                            highlightedSuggestionText(term: term, query: trimmed)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if term.lowercased() != q {
                                        Button {
                                            text = term
                                        } label: {
                                            Image(systemName: "arrow.up.left")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 28, height: 28)
                                                .background(Color(.tertiarySystemFill), in: Circle())
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    }

                    if !libraryItems.isEmpty {
                        Section(L10n.t("书签、历史记录和标签页", "Bookmarks & History")) {
                            ForEach(libraryItems) { item in
                                Button {
                                    onSubmit(item.url)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color(.tertiarySystemFill))
                                                .frame(width: 30, height: 30)
                                            Image(systemName: item.isBookmark ? "bookmark.fill" : "clock")
                                                .font(.system(size: 13))
                                                .foregroundStyle(item.isBookmark ? .blue : .secondary)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(item.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if canFindInPage && !trimmed.isEmpty {
                        Section(L10n.t("此页", "On This Page")) {
                            Button {
                                onFindInPage(trimmed)
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color(.tertiarySystemFill))
                                            .frame(width: 30, height: 30)
                                        Image(systemName: "doc.text.magnifyingglass")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(L10n.t("查找“\(trimmed)”", "Find “\(trimmed)”"))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .padding(.top, 10)
            .navigationTitle(L10n.t("地址与搜索", "Navigate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) { dismiss() }
                }
            }
            .onAppear {
                remoteSuggester.update(query: text, engine: searchEngine)
            }
            .onChange(of: text) { _, newValue in
                remoteSuggester.update(query: newValue, engine: searchEngine)
            }
        }
    }

    private func buildRemoteSearchList(trimmed: String, rawLower: String, remote: [String]) -> [String] {
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = [trimmed]
        var seen: Set<String> = [rawLower]
        for term in remote {
            let low = term.lowercased()
            if seen.contains(low) { continue }
            seen.insert(low)
            out.append(term)
            if out.count >= 6 { break }
        }
        return out
    }

    private func highlightedSuggestionText(term: String, query: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let range = term.range(of: q, options: .caseInsensitive) else {
            return Text(term).foregroundStyle(.primary)
        }
        let before = String(term[..<range.lowerBound])
        let match = String(term[range])
        let after = String(term[range.upperBound...])
        return Text(before).foregroundStyle(.secondary)
            + Text(match).bold().foregroundStyle(.primary)
            + Text(after).foregroundStyle(.secondary)
    }

    private func normalizeKey(_ raw: String) -> String {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return raw.lowercased()
        }
        let host = (u.host ?? "").lowercased()
        let path = (u.path == "/" || u.path.isEmpty) && u.query == nil ? "" : u.path
        return "\(host)\(path)\(u.query.map { "?\($0)" } ?? "")"
    }

    private func hostOnly(_ raw: String) -> String {
        if let host = URL(string: raw)?.host?.lowercased() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return raw
    }

    private func relativeTime(_ visitedAtMs: Double) -> String {
        let sec = max(0, Date().timeIntervalSince1970 - visitedAtMs / 1000.0)
        if sec < 60 { return L10n.t("刚刚曾访问", "Visited just now") }
        let mins = Int(sec / 60)
        if mins < 60 { return L10n.t("\(mins)分钟前曾访问", "Visited \(mins)m ago") }
        let hours = Int(sec / 3600)
        if hours < 24 { return L10n.t("\(hours)小时前曾访问", "Visited \(hours)h ago") }
        let days = Int(sec / 86400)
        if days < 14 { return L10n.t("\(days)天前曾访问", "Visited \(days)d ago") }
        let weeks = Int(days / 7)
        return L10n.t("\(weeks)周前曾访问", "Visited \(weeks)w ago")
    }

    private func scoreMatch(queryLower: String, tokens: [String], title: String, url: String) -> Int {
        let titleLow = title.lowercased()
        let urlLow = url.lowercased()
        let hostLow = hostOnly(url)
        for tok in tokens {
            if !titleLow.contains(tok) && !urlLow.contains(tok) {
                return 0
            }
        }
        var score = 15
        if titleLow == queryLower || hostLow == queryLower { score += 120 }
        else if hostLow.hasPrefix(queryLower) || titleLow.hasPrefix(queryLower) { score += 80 }
        else if urlLow.contains("://\(queryLower)") || urlLow.contains(".\(queryLower)") { score += 55 }
        else if titleLow.contains(queryLower) { score += 35 }
        else if urlLow.contains(queryLower) { score += 25 }
        return score
    }

    private func buildLocalCandidates(queryLower: String, tokens: [String]) -> (topHit: OmniboxCandidateEntry?, tabs: [OmniboxCandidateEntry], library: [OmniboxCandidateEntry]) {
        var seen = Set<String>()

        if queryLower.isEmpty {
            var tabEntries: [OmniboxCandidateEntry] = []
            for t in tabs where !t.isNewTab && t.id != activeTabId {
                let k = normalizeKey(t.urlString)
                if seen.contains(k) { continue }
                seen.insert(k)
                let host = hostOnly(t.urlString)
                tabEntries.append(OmniboxCandidateEntry(
                    id: "tab-\(t.id.uuidString)",
                    title: t.title.isEmpty ? host : t.title,
                    url: t.urlString,
                    subtitle: "\(host) · \(L10n.t("打开的标签页", "Open Tab"))",
                    isBookmark: false,
                    tabId: t.id,
                    score: 50,
                    visitedAt: 0
                ))
                if tabEntries.count >= 3 { break }
            }
            var libEntries: [OmniboxCandidateEntry] = []
            for h in history {
                let k = normalizeKey(h.url)
                if seen.contains(k) { continue }
                seen.insert(k)
                let host = hostOnly(h.url)
                libEntries.append(OmniboxCandidateEntry(
                    id: "hist-\(h.id)",
                    title: h.title.isEmpty ? host : h.title,
                    url: h.url,
                    subtitle: "\(host) · \(relativeTime(h.visitedAt))",
                    isBookmark: false,
                    tabId: nil,
                    score: 20,
                    visitedAt: h.visitedAt
                ))
                if libEntries.count >= 8 { break }
            }
            for bm in bookmarks where bm.type != "folder" {
                if libEntries.count >= 10 { break }
                let k = normalizeKey(bm.url)
                if seen.contains(k) { continue }
                seen.insert(k)
                let host = hostOnly(bm.url)
                libEntries.append(OmniboxCandidateEntry(
                    id: "bm-\(bm.id)",
                    title: bm.title.isEmpty ? host : bm.title,
                    url: bm.url,
                    subtitle: "\(host) · \(L10n.t("书签", "Bookmark"))",
                    isBookmark: true,
                    tabId: nil,
                    score: 20,
                    visitedAt: bm.createdAt
                ))
            }
            return (nil, tabEntries, libEntries)
        }

        // Non-empty query: rank Top Hit + matching Open Tabs + Bookmarks & History
        var scoredSites: [OmniboxCandidateEntry] = []
        var tabMatches: [OmniboxCandidateEntry] = []

        for t in tabs where !t.isNewTab {
            let s = scoreMatch(queryLower: queryLower, tokens: tokens, title: t.title, url: t.urlString)
            if s > 0 {
                let host = hostOnly(t.urlString)
                tabMatches.append(OmniboxCandidateEntry(
                    id: "tab-\(t.id.uuidString)",
                    title: t.title.isEmpty ? host : t.title,
                    url: t.urlString,
                    subtitle: "\(host) · \(L10n.t("打开的标签页", "Open Tab"))",
                    isBookmark: false,
                    tabId: t.id,
                    score: s + 8,
                    visitedAt: Date().timeIntervalSince1970 * 1000
                ))
            }
        }
        tabMatches.sort { $0.score > $1.score }

        for bm in bookmarks where bm.type != "folder" {
            let s = scoreMatch(queryLower: queryLower, tokens: tokens, title: bm.title, url: bm.url)
            if s > 0 {
                let host = hostOnly(bm.url)
                scoredSites.append(OmniboxCandidateEntry(
                    id: "bm-\(bm.id)",
                    title: bm.title.isEmpty ? host : bm.title,
                    url: bm.url,
                    subtitle: host,
                    isBookmark: true,
                    tabId: nil,
                    score: s + 12,
                    visitedAt: bm.createdAt
                ))
            }
        }
        for sc in shortcuts {
            let s = scoreMatch(queryLower: queryLower, tokens: tokens, title: sc.title, url: sc.url)
            if s > 0 {
                let host = hostOnly(sc.url)
                scoredSites.append(OmniboxCandidateEntry(
                    id: "sc-\(sc.id)",
                    title: sc.title.isEmpty ? host : sc.title,
                    url: sc.url,
                    subtitle: host,
                    isBookmark: true,
                    tabId: nil,
                    score: s + 10,
                    visitedAt: 0
                ))
            }
        }
        for h in history {
            let s = scoreMatch(queryLower: queryLower, tokens: tokens, title: h.title, url: h.url)
            if s > 0 {
                let host = hostOnly(h.url)
                scoredSites.append(OmniboxCandidateEntry(
                    id: "hist-\(h.id)",
                    title: h.title.isEmpty ? host : h.title,
                    url: h.url,
                    subtitle: "\(host) · \(relativeTime(h.visitedAt))",
                    isBookmark: false,
                    tabId: nil,
                    score: s,
                    visitedAt: h.visitedAt
                ))
            }
        }
        scoredSites.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.visitedAt > $1.visitedAt
        }

        var topHit: OmniboxCandidateEntry? = nil
        if let best = scoredSites.first, best.score >= 70 {
            let host = hostOnly(best.url)
            topHit = OmniboxCandidateEntry(
                id: "top-\(best.id)",
                title: best.title,
                url: best.url,
                subtitle: host,
                isBookmark: best.isBookmark,
                tabId: nil,
                score: best.score,
                visitedAt: best.visitedAt
            )
            seen.insert(normalizeKey(best.url))
        }

        var outTabs: [OmniboxCandidateEntry] = []
        for t in tabMatches where t.tabId != activeTabId {
            let k = normalizeKey(t.url)
            if seen.contains(k) && topHit?.title.lowercased() == t.title.lowercased() { continue }
            outTabs.append(t)
            seen.insert(k)
            if outTabs.count >= 2 { break }
        }

        var outLib: [OmniboxCandidateEntry] = []
        for item in scoredSites {
            let k = normalizeKey(item.url)
            if seen.contains(k) { continue }
            seen.insert(k)
            let subtitle = item.isBookmark ? "\(hostOnly(item.url)) · \(L10n.t("书签", "Bookmark"))" : item.subtitle
            outLib.append(OmniboxCandidateEntry(
                id: item.id,
                title: item.title,
                url: item.url,
                subtitle: subtitle,
                isBookmark: item.isBookmark,
                tabId: nil,
                score: item.score,
                visitedAt: item.visitedAt
            ))
            if outLib.count >= 6 { break }
        }

        return (topHit, outTabs, outLib)
    }
}

private struct PrismTactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct VideoMiniStrip: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var handoffService: HandoffService
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    let onRequireAccount: () -> Void

    var body: some View {
        Button {
            guard syncEngine.loggedIn else {
                tabManager.showToast(L10n.t("请先登录 Prism Account 使用桌面续播", "Sign in to Prism Account to continue on desktop"))
                onRequireAccount()
                return
            }
            Task {
                let ok = await handoffService.push(
                    kind: "video",
                    title: tab.title,
                    url: tab.urlString,
                    videoSeconds: tab.videoSeconds,
                    syncEngine: syncEngine
                )
                tabManager.showToast(ok ? L10n.t("已带进度接力至桌面端", "Sent video to desktop") : L10n.t("发送失败", "Failed"))
            }
        } label: {
            Label(L10n.t("桌面续播", "Continue on Desktop"), systemImage: "laptopcomputer")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(PrismTactileButtonStyle())
    }
}

private struct AutofillBar: View {
    let entries: [PasswordEntry]
    let primary: PasswordEntry
    let onFill: (PasswordEntry) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "faceid").foregroundStyle(.blue)
            Button {
                onFill(primary)
            } label: {
                Text(L10n.t("使用 \(primary.username) 自动填充", "Fill \(primary.username)"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct SavePasswordBanner: View {
    let initialUsername: String
    let onSave: (String) -> Void
    let onDismiss: () -> Void
    @State private var editedUsername: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("保存密码并云同步？", "Save & sync password?"))
                    .font(.caption.weight(.semibold))
                TextField(L10n.t("账号/邮箱", "Username"), text: $editedUsername)
                    .font(.caption2)
                    .keyboardType(.default)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .onAppear { editedUsername = initialUsername }
            }
            Spacer()
            Button(L10n.t("保存", "Save")) {
                onSave(editedUsername)
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct BlockedAppJumpBanner: View {
    let url: URL
    let onAllowOnce: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "hand.raised.shield.fill").foregroundStyle(.orange)
            Text(L10n.t("已拦截自动跳转外部 App", "Blocked external app jump"))
                .font(.caption.weight(.medium))
            Spacer()
            Button(L10n.t("允许一次", "Allow Once"), action: onAllowOnce)
                .font(.caption.weight(.semibold))
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HandoffBannerView: View {
    let payload: HandoffPayload
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let displayTitle = (payload.title?.isEmpty == false ? payload.title : nil) ?? payload.url ?? payload.text ?? ""
        HStack(spacing: 8) {
            Button(action: onOpen) {
                Text("💻 " + L10n.t("来自电脑：", "From Desktop: ") + displayTitle + " · " + L10n.t("立即打开", "Open Now"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }
}

private struct TopCapsuleToastView: View {
    let toast: ToastNotice
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.message)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let actionTitle = toast.actionTitle {
                Button(actionTitle, action: onAction)
                    .font(.caption.weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }
}

private struct ToastBannerView: View {
    let toast: ToastNotice
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Text(toast.message)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer()
            if let actionTitle = toast.actionTitle {
                Button(actionTitle, action: onAction)
                    .font(.caption.weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
