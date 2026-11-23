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
    @State private var prevPlaybackRateBefore2x: Double = 1.0
    @State private var scrubOffsetSec: Double = 0
    @State private var isScrubbingVideo = false
    @State private var isChromeCollapsed = false
    @State private var topCapsuleToast: ToastNotice?
    @State private var topToastDismissTask: Task<Void, Never>?

    enum ActiveSheet: Identifiable {
        case menu, account, profiles, vault, sniffer, devtools, reader, downloads, bookmarksHistory
        var id: Self { self }
    }

    var body: some View {
        let currentTab = tabManager.activeTab
        let showFullDock = (currentTab?.isNewTab ?? true) || !isChromeCollapsed

        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                if let tab = currentTab {
                    if tab.isNewTab {
                        HomeNewTabView(syncEngine: syncEngine, tabManager: tabManager) {
                            omniboxInput = ""
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                showOmniboxEditor = true
                            }
                        }
                    } else {
                        WebViewControllerRepresentable(
                            tabId: tab.id,
                            tab: tab,
                            tabManager: tabManager,
                            bottomChromeInset: isChromeCollapsed ? 36 : 96,
                            onScrollCollapsedChange: { collapsed in
                                guard isChromeCollapsed != collapsed else { return }
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    isChromeCollapsed = collapsed
                                }
                            }
                        )
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                        .transaction { $0.animation = nil }

                        // Right-edge Long Press 2.0x Gesture Strip (unobtrusive 44pt edge, restores tab.playbackRate on release)
                        if tab.hasVideo {
                            HStack {
                                Spacer()
                                Color.clear
                                    .frame(width: 44)
                                    .contentShape(Rectangle())
                                    .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
                                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                        if pressing {
                                            prevPlaybackRateBefore2x = tab.playbackRate
                                        }
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                            isSpeed2x = pressing
                                        }
                                        let rate = pressing ? 2.0 : prevPlaybackRateBefore2x
                                        tab.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('rate', \(rate));", completionHandler: nil)
                                    }, perform: {})
                            }
                        }
                    }
                }

                // Slim Smooth Loading Bar (isolated leaf view so progress updates don't diff root tree)
                if let tab = currentTab, !tab.isNewTab {
                    TabLoadingProgressBar(tab: tab)
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

                if let tab = currentTab {
                    ActiveTabBannersView(tab: tab, tabManager: tabManager)
                }

                // Always-visible Floating Handoff Pill above Dock on every non-newTab webpage
                if let tab = currentTab, !tab.isNewTab, showFullDock {
                    VideoMiniStrip(
                        tab: tab,
                        handoffService: handoffService,
                        syncEngine: syncEngine,
                        tabManager: tabManager,
                        onRequireAccount: { activeSheet = .account },
                        onVideoScrub: { deltaX, ended in
                            if !ended {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                                    isScrubbingVideo = true
                                }
                                scrubOffsetSec = Double(deltaX / 6.0)
                            } else {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    isScrubbingVideo = false
                                }
                                let sec = scrubOffsetSec
                                tab.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('seekBy', \(sec));", completionHandler: nil)
                            }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Single-Hand 52pt Bottom Thumb Dock or 24pt Immersive Domain Pill
                if showFullDock {
                    BottomThumbDock(
                        syncEngine: syncEngine,
                        tabManager: tabManager,
                        handoffService: handoffService,
                        onTapOmnibox: {
                            omniboxInput = ""
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                showOmniboxEditor = true
                            }
                        },
                        onOpenTabs: {
                            tabManager.captureActiveSnapshot()
                            showTabSwitcher = true
                        },
                        onOpenProfiles: { activeSheet = .profiles },
                        onOpenMenu: { activeSheet = .menu },
                        onRequireAccount: { activeSheet = .account },
                        onSwitchTabOffset: { offset in
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                tabManager.switchTab(byOffset: offset)
                            }
                        },
                        onPullUpTabs: {
                            tabManager.captureActiveSnapshot()
                            showTabSwitcher = true
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let tab = currentTab, !tab.isNewTab {
                    CollapsedDomainPill(tab: tab) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            isChromeCollapsed = false
                        }
                    }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, showFullDock ? 8 : 4)
            .onChange(of: tabManager.activeTabId) { _, _ in
                if isChromeCollapsed {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        isChromeCollapsed = false
                    }
                }
            }

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

            // Safari-Style Inline Omnibox Candidate Overlay Directly Above Bottom Search Bar
            if showOmniboxEditor {
                OmniboxInlineOverlay(
                    text: $omniboxInput,
                    bookmarks: syncEngine.bookmarks,
                    history: syncEngine.history,
                    tabs: tabManager.tabs,
                    activeTab: currentTab,
                    shortcuts: syncEngine.homeConfig.shortcuts,
                    searchEngine: tabManager.searchEngine,
                    enterTopHitEnabled: $tabManager.omniboxEnterTopHitEnabled,
                    hasClipboardWebURL: tabManager.hasClipboardWebURL,
                    canFindInPage: !(currentTab?.isNewTab ?? true),
                    onRefreshClipboardPattern: {
                        tabManager.refreshClipboardWebURLPatternSilently()
                    },
                    onSubmit: { target in
                        tabManager.navigateActive(target)
                        withAnimation(.easeOut(duration: 0.14)) {
                            showOmniboxEditor = false
                        }
                    },
                    onSelectTab: { tabId in
                        tabManager.activateTab(id: tabId)
                        withAnimation(.easeOut(duration: 0.14)) {
                            showOmniboxEditor = false
                        }
                    },
                    onFindInPage: { query in
                        withAnimation(.easeOut(duration: 0.14)) {
                            showOmniboxEditor = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            tabManager.findInActivePage(query)
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.14)) {
                            showOmniboxEditor = false
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(50)
            }
        }
        .onAppear {
            handleIncomingHandoff(handoffService.latestIncoming)
        }
        .onChange(of: handoffService.latestIncoming) { _, incoming in
            handleIncomingHandoff(incoming)
        }
        .sheet(isPresented: $showTabSwitcher) {
            TabSwitcherView(tabManager: tabManager, syncEngine: syncEngine, handoffService: handoffService)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .menu:
                MenuSheetView(syncEngine: syncEngine, tabManager: tabManager, handoffService: handoffService) { target in
                    activeSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                        activeSheet = target
                    }
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
            case .reader:
                ReaderModeSheetView(tabManager: tabManager)
            case .downloads:
                DownloadsSheetView(tabManager: tabManager)
            case .bookmarksHistory:
                BookmarksHistorySheetView(syncEngine: syncEngine, tabManager: tabManager)
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

private struct CollapsedDomainPill: View {
    @ObservedObject var tab: BrowserTab
    let onExpand: () -> Void

    var body: some View {
        let host = SmartOmniboxEngine.hostOnly(tab.urlString)
        Button(action: onExpand) {
            ZStack(alignment: .bottom) {
                HStack(spacing: 5) {
                    if tab.urlString.hasPrefix("https://") {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    Text(host.isEmpty ? tab.title : host)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 24)

                if tab.isLoading && tab.estimatedProgress < 0.995 {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(12, geo.size.width * CGFloat(tab.estimatedProgress)), height: 1.5)
                    }
                    .frame(height: 1.5)
                    .padding(.horizontal, 10)
                }
            }
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
        }
        .buttonStyle(PrismTactileButtonStyle())
    }
}

private struct BottomThumbDock: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    @ObservedObject var handoffService: HandoffService
    let onTapOmnibox: () -> Void
    let onOpenTabs: () -> Void
    let onOpenProfiles: () -> Void
    let onOpenMenu: () -> Void
    let onRequireAccount: () -> Void
    let onSwitchTabOffset: (Int) -> Void
    let onPullUpTabs: () -> Void

    var body: some View {
        let activeTab = tabManager.activeTab
        let profile = tabManager.activeProfile

        HStack(spacing: 8) {
            if let tab = activeTab {
                DockBackButton(tab: tab)
            } else {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 36)
            }

            // Profile Color Pill
            Button(action: onOpenProfiles) {
                Circle()
                    .fill(profile.swiftColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 28, height: 36)
            }

            // Central Interactive Omnibox Pill (Zero nested Buttons; Swipe L/R strictly switches tabs)
            if let tab = activeTab {
                DockAddressPill(
                    tab: tab,
                    tabManager: tabManager,
                    syncEngine: syncEngine,
                    handoffService: handoffService,
                    onTapOmnibox: onTapOmnibox,
                    onRequireAccount: onRequireAccount,
                    onSwitchTabOffset: onSwitchTabOffset,
                    onPullUpTabs: onPullUpTabs
                )
            }

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
}

private struct DockBackButton: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        let canBack = tab.canGoBack
        let canForward = tab.canGoForward
        Button {
            if tab.canGoBack {
                tab.webView?.goBack()
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .disabled(!canBack && !canForward)
        .contextMenu {
            if canForward, let fwd = tab.webView?.backForwardList.forwardItem {
                Button {
                    tab.webView?.goForward()
                } label: {
                    Label(
                        L10n.t("前进：\(fwd.title ?? fwd.url.host ?? "")", "Forward: \(fwd.title ?? fwd.url.host ?? "")"),
                        systemImage: "chevron.right"
                    )
                }
            }
            if let backItems = tab.webView?.backForwardList.backList.reversed().prefix(8), !backItems.isEmpty {
                Section(L10n.t("后退历史", "History")) {
                    ForEach(Array(backItems), id: \.url) { item in
                        Button {
                            tab.webView?.go(to: item)
                        } label: {
                            Text((item.title?.isEmpty == false ? item.title : nil) ?? item.url.host ?? item.url.absoluteString)
                        }
                    }
                }
            }
        }
    }
}

private struct DockAddressPill: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var tabManager: TabManager
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var handoffService: HandoffService
    let onTapOmnibox: () -> Void
    let onRequireAccount: () -> Void
    let onSwitchTabOffset: (Int) -> Void
    let onPullUpTabs: () -> Void

    @State private var swipeOffsetX: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTapOmnibox) {
                HStack(spacing: 6) {
                    if !tab.isNewTab, tab.urlString.hasPrefix("https://") {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Text(displayOmniboxLabel(tab))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .padding(.trailing, tab.isNewTab ? 12 : 4)
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !tab.isNewTab {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if tab.isLoading {
                        tab.webView?.stopLoading()
                    } else {
                        tab.webView?.reload()
                    }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 36)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .offset(x: swipeOffsetX)
        .contextMenu {
            Button {
                if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                    tabManager.navigateActive(pasted)
                }
            } label: {
                Label(L10n.t("粘贴并前往", "Paste & Go"), systemImage: "doc.on.clipboard")
            }

            if !tab.isNewTab && !tab.urlString.isEmpty {
                Button {
                    UIPasteboard.general.string = tab.urlString
                    tabManager.syncClipboardChangeCount()
                    tabManager.showToast(L10n.t("已复制当前网址", "URL copied"))
                } label: {
                    Label(L10n.t("复制当前网址", "Copy Current URL"), systemImage: "link")
                }

                if let shareUrl = URL(string: tab.urlString) {
                    Button {
                        BrowserRootView.presentSystemShareSheet(items: [shareUrl])
                    } label: {
                        Label(L10n.t("系统分享网页", "Share Page"), systemImage: "square.and.arrow.up")
                    }
                }

                Button {
                    guard syncEngine.loggedIn else {
                        onRequireAccount()
                        return
                    }
                    Task {
                        let ok = await handoffService.push(
                            kind: tab.hasVideo ? "video" : "tab",
                            title: tab.title,
                            url: tab.urlString,
                            videoSeconds: tab.hasVideo ? tab.videoSeconds : 0,
                            syncEngine: syncEngine
                        )
                        tabManager.showToast(ok ? L10n.t("已推送到电脑端", "Sent to desktop") : L10n.t("发送失败", "Failed"))
                    }
                } label: {
                    Label(L10n.t("发送至电脑", "Send to Desktop"), systemImage: "laptopcomputer")
                }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { val in
                    if abs(val.translation.width) > abs(val.translation.height) && tabManager.tabs.count > 1 {
                        let raw = val.translation.width
                        swipeOffsetX = max(-30, min(30, raw * 0.35))
                    }
                }
                .onEnded { val in
                    let dx = val.translation.width
                    let dy = val.translation.height
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        swipeOffsetX = 0
                    }
                    if dy < -45 && abs(dy) > abs(dx) {
                        onPullUpTabs()
                    } else if abs(dx) > abs(dy) {
                        if dx < -50 {
                            onSwitchTabOffset(1)
                        } else if dx > 50 {
                            onSwitchTabOffset(-1)
                        }
                    }
                }
        )
    }

    private func displayOmniboxLabel(_ tab: BrowserTab) -> String {
        guard !tab.isNewTab else {
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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event, event.type == .touches {
            tabManager?.markActiveTabUserInteraction()
        }
        return super.hitTest(point, with: event)
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

private struct ActiveTabBannersView: View {
    @ObservedObject var tab: BrowserTab
    let tabManager: TabManager

    var body: some View {
        Group {
            if let blockedUrl = tab.blockedAppJumpURL {
                BlockedAppJumpBanner(url: blockedUrl) {
                    tabManager.allowOnceAppJump(blockedUrl)
                } onDismiss: {
                    tab.blockedAppJumpURL = nil
                }
            }

            if let pending = tab.pendingPasswordSave {
                SavePasswordBanner(initialUsername: pending.username) { editedUser in
                    tabManager.savePendingPassword(usernameOverride: editedUser)
                } onDismiss: {
                    tab.pendingPasswordSave = nil
                }
            }

            if tab.showAutofillBar, let firstCred = tab.matchedPasswords.first {
                AutofillBar(entries: tab.matchedPasswords, primary: firstCred) { chosen in
                    tabManager.autofillWithFaceID(entry: chosen)
                } onDismiss: {
                    tab.showAutofillBar = false
                }
            }
        }
    }
}

private struct TabLoadingProgressBar: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        let progress = max(0.0, min(1.0, tab.estimatedProgress))
        if tab.isLoading && progress < 0.995 {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(18, geo.size.width * CGFloat(progress)), height: 2.5)
                    .animation(.linear(duration: 0.12), value: progress)
            }
            .frame(height: 2.5)
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .horizontal)
        }
    }
}

@MainActor
final class PrismWebViewController: UIViewController {
    let containerView = PrismWebContainerView(frame: .zero)
    var onScrollCollapsedChange: ((Bool) -> Void)?
    private var attachedTabId: UUID?
    private weak var refreshWebView: WKWebView?
    private var scrollOffsetObservation: NSKeyValueObservation?
    private var lastOffsetY: CGFloat = 0
    private var scrollDeltaAccumulator: CGFloat = 0
    private var isCurrentlyCollapsed: Bool = false
    private var currentBottomChromeInset: CGFloat = 96

    override func loadView() {
        view = containerView
    }

    func attach(tab: BrowserTab, tabManager: TabManager, bottomChromeInset: CGFloat) {
        let target = tabManager.ensureWebView(for: tab)
        if attachedTabId == tab.id, containerView.hostedWebView === target {
            updateBottomChromeInset(bottomChromeInset, on: target)
            return
        }
        attachedTabId = tab.id
        scrollDeltaAccumulator = 0
        isCurrentlyCollapsed = false
        lastOffsetY = target.scrollView.contentOffset.y
        containerView.attachWebView(target, tabManager: tabManager, targetURL: target.url ?? URL(string: tab.urlString))
        attachRefreshControl(to: target)
        observeScroll(on: target)
        updateBottomChromeInset(bottomChromeInset, on: target, force: true)
    }

    func updateBottomChromeInset(_ insetBottom: CGFloat, on webView: WKWebView? = nil, force: Bool = false) {
        let targetWebView = webView ?? containerView.hostedWebView
        guard let targetWebView else { return }
        if !force && abs(currentBottomChromeInset - insetBottom) <= 0.5 && abs(targetWebView.scrollView.contentInset.bottom - insetBottom) <= 0.5 {
            return
        }
        currentBottomChromeInset = insetBottom
        var contentInset = targetWebView.scrollView.contentInset
        contentInset.bottom = insetBottom
        targetWebView.scrollView.contentInset = contentInset
        var indicatorInset = targetWebView.scrollView.verticalScrollIndicatorInsets
        indicatorInset.bottom = insetBottom
        targetWebView.scrollView.verticalScrollIndicatorInsets = indicatorInset
    }

    private func observeScroll(on webView: WKWebView) {
        scrollOffsetObservation?.invalidate()
        scrollOffsetObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self, weak webView] _, _ in
            guard let webView else { return }
            let sv = webView.scrollView
            let y = sv.contentOffset.y
            let maxY = max(0, sv.contentSize.height - sv.bounds.height)
            let isDragging = sv.isDragging || sv.isTracking || sv.isDecelerating
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleScrollOffset(y: y, maxY: maxY, isInteractive: isDragging)
            }
        }
    }

    private func handleScrollOffset(y: CGFloat, maxY: CGFloat, isInteractive: Bool) {
        // Expand dock immediately at top region (protects pull-to-refresh)
        if y <= 10 {
            lastOffsetY = y
            scrollDeltaAccumulator = 0
            if isCurrentlyCollapsed {
                isCurrentlyCollapsed = false
                onScrollCollapsedChange?(false)
            }
            return
        }

        // Ignore bottom rubber-band bounce zone
        if maxY > 80 && y >= maxY - 4 {
            lastOffsetY = y
            return
        }

        let dy = y - lastOffsetY
        lastOffsetY = y
        guard isInteractive, abs(dy) > 0.2 else { return }

        if (scrollDeltaAccumulator >= 0 && dy >= 0) || (scrollDeltaAccumulator <= 0 && dy <= 0) {
            scrollDeltaAccumulator += dy
        } else {
            scrollDeltaAccumulator = dy
        }

        if scrollDeltaAccumulator > 24 && !isCurrentlyCollapsed {
            isCurrentlyCollapsed = true
            scrollDeltaAccumulator = 0
            onScrollCollapsedChange?(true)
        } else if scrollDeltaAccumulator < -24 && isCurrentlyCollapsed {
            isCurrentlyCollapsed = false
            scrollDeltaAccumulator = 0
            onScrollCollapsedChange?(false)
        }
    }

    private func attachRefreshControl(to webView: WKWebView) {
        refreshWebView = webView
        webView.scrollView.bounces = true
        if webView.scrollView.refreshControl == nil {
            let rc = UIRefreshControl()
            rc.addTarget(self, action: #selector(handlePullToRefresh(_:)), for: .valueChanged)
            webView.scrollView.refreshControl = rc
        }
    }

    @objc private func handlePullToRefresh(_ sender: UIRefreshControl) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refreshWebView?.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if sender.isRefreshing {
                sender.endRefreshing()
            }
        }
    }
}

struct WebViewControllerRepresentable: UIViewControllerRepresentable {
    let tabId: UUID
    let tab: BrowserTab
    let tabManager: TabManager
    let bottomChromeInset: CGFloat
    var onScrollCollapsedChange: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> PrismWebViewController {
        let vc = PrismWebViewController()
        vc.onScrollCollapsedChange = onScrollCollapsedChange
        vc.attach(tab: tab, tabManager: tabManager, bottomChromeInset: bottomChromeInset)
        return vc
    }

    func updateUIViewController(_ uiViewController: PrismWebViewController, context: Context) {
        uiViewController.onScrollCollapsedChange = onScrollCollapsedChange
        uiViewController.attach(tab: tab, tabManager: tabManager, bottomChromeInset: bottomChromeInset)
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

extension BrowserRootView {
    @MainActor
    static func presentSystemShareSheet(items: [Any]) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController else {
            return
        }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
}

private struct VideoMiniStrip: View {
    enum SendState { case idle, sending, sent }

    @ObservedObject var tab: BrowserTab
    @ObservedObject var handoffService: HandoffService
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    let onRequireAccount: () -> Void
    var onVideoScrub: ((CGFloat, Bool) -> Void)? = nil

    @State private var sendState: SendState = .idle
    @State private var displayTick: Int = 0

    private let videoClockTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            guard sendState == .idle else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard syncEngine.loggedIn else {
                tabManager.showToast(L10n.t("请先登录 Prism Account 使用桌面续播", "Sign in to Prism Account to continue on desktop"))
                onRequireAccount()
                return
            }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                sendState = .sending
            }
            Task {
                let ok = await handoffService.push(
                    kind: tab.hasVideo ? "video" : "tab",
                    title: tab.title,
                    url: tab.urlString,
                    videoSeconds: tab.hasVideo ? tab.videoSeconds : 0,
                    syncEngine: syncEngine
                )
                if ok {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        sendState = .sent
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                } else {
                    tabManager.showToast(L10n.t("发送失败", "Failed"))
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    sendState = .idle
                }
            }
        } label: {
            HStack(spacing: 6) {
                switch sendState {
                case .idle:
                    Image(systemName: "laptopcomputer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(idleLabelText)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                case .sending:
                    ProgressView()
                        .scaleEffect(0.68)
                        .frame(width: 14, height: 14)
                    Text(L10n.t("正在同步...", "Sending..."))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                case .sent:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(L10n.t("已发送至电脑", "Sent to Desktop"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(sendState == .sent ? Color.green.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(PrismTactileButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { val in
                    guard tab.hasVideo, abs(val.translation.width) > abs(val.translation.height) else { return }
                    onVideoScrub?(val.translation.width, false)
                }
                .onEnded { val in
                    guard tab.hasVideo, abs(val.translation.width) > abs(val.translation.height) else { return }
                    onVideoScrub?(val.translation.width, true)
                }
        )
        .onReceive(videoClockTimer) { _ in
            if tab.hasVideo && !tab.videoPaused && tab.videoDuration > 0 {
                displayTick += 1
            }
        }
    }

    private var idleLabelText: String {
        _ = displayTick
        let base = L10n.t("桌面续播", "Continue on Desktop")
        if tab.hasVideo && tab.videoDuration > 0 {
            let sec = max(0, Int(tab.videoSeconds.rounded()))
            let mins = sec / 60
            let rem = sec % 60
            return "\(base) · \(String(format: "%02d:%02d", mins, rem))"
        }
        return base
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
        let appName = AppJumpShield.friendlyAppName(for: url)
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.shield.fill")
                .foregroundStyle(.orange)
            Text(L10n.t("已拦截跳转至 \(appName)", "Blocked jump to \(appName)"))
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(L10n.t("允许一次", "Allow Once"), action: onAllowOnce)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12), in: Capsule())
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
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
