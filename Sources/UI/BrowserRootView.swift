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

    enum ActiveSheet: Identifiable {
        case menu, account, profiles, vault, sniffer, devtools
        var id: Self { self }
    }

    var body: some View {
        let currentTab = tabManager.activeTab
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Slim Loading Bar
                if let tab = currentTab, tab.isLoading && !tab.isNewTab {
                    ProgressView(value: tab.estimatedProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                }

                // Main Content (New Tab or WebView + Video Touch Overlays)
                ZStack {
                    if let tab = currentTab {
                        if tab.isNewTab {
                            HomeNewTabView(syncEngine: syncEngine, tabManager: tabManager)
                        } else {
                            WebViewRepresentable(tab: tab, tabManager: tabManager)
                                .ignoresSafeArea(.container, edges: .bottom)

                            // Right-edge Long Press 2.0x Gesture Strip (unobtrusive 28pt edge)
                            if tab.hasVideo {
                                HStack {
                                    Spacer()
                                    Color.clear
                                        .frame(width: 44)
                                        .contentShape(Rectangle())
                                        .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
                                            isSpeed2x = pressing
                                            let rate = pressing ? 2.0 : 1.0
                                            tab.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('rate', \(rate));", completionHandler: nil)
                                        }, perform: {})
                                }
                            }
                        }
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
                        .transition(.opacity)
                    }

                    // Horizontal scrub feedback pill
                    if isScrubbingVideo {
                        Text(String(format: "%+.0fs", scrubOffsetSec))
                            .font(.title3.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.75), in: Capsule())
                    }
                }
            }

            // Floating Overlays Above Bottom Thumb Bar
            VStack(spacing: 8) {
                if let handoff = handoffService.latestIncoming {
                    HandoffBannerView(payload: handoff) {
                        if let raw = handoff.url, let url = URL(string: raw) {
                            let tab = tabManager.createTab(url: url, activate: true)
                            if handoff.kind == "video", let secs = handoff.videoSeconds, secs > 2 {
                                tabManager.load(url: url, in: tab, seekSeconds: secs)
                            }
                        } else if let text = handoff.text {
                            UIPasteboard.general.string = text
                            tabManager.showToast(L10n.t("已复制桌面端推送的剪贴板内容", "Copied clipboard from desktop"))
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

                if let tab = currentTab, tab.pendingPasswordSave != nil {
                    SavePasswordBanner {
                        tabManager.savePendingPassword()
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

                // Video Quick Control Strip when video detected on page
                if let tab = currentTab, tab.hasVideo && !tab.isNewTab {
                    VideoMiniStrip(tab: tab, handoffService: handoffService, syncEngine: syncEngine, tabManager: tabManager) {
                        activeSheet = .sniffer
                    }
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
                                isScrubbingVideo = true
                                scrubOffsetSec = Double(deltaX / 8.0)
                            } else {
                                isScrubbingVideo = false
                                let sec = scrubOffsetSec
                                tabManager.activeTab?.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('seekBy', \(sec));", completionHandler: nil)
                            }
                        } else if ended {
                            if deltaX < -55 {
                                tabManager.switchTab(byOffset: 1)
                            } else if deltaX > 55 {
                                tabManager.switchTab(byOffset: -1)
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
        }
        .sheet(isPresented: $showOmniboxEditor) {
            OmniboxEditorSheet(
                text: $omniboxInput,
                bookmarks: syncEngine.bookmarks,
                history: syncEngine.history
            ) { target in
                tabManager.navigateActive(target)
                showOmniboxEditor = false
            }
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

struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var tabManager: TabManager

    func makeUIView(context: Context) -> WKWebView {
        tabManager.ensureWebView(for: tab)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let target = tabManager.ensureWebView(for: tab)
        if uiView !== target, let superview = uiView.superview {
            target.frame = uiView.frame
            superview.insertSubview(target, aboveSubview: uiView)
            uiView.removeFromSuperview()
        }
    }
}

private struct OmniboxEditorSheet: View {
    @Binding var text: String
    let bookmarks: [BookmarkItem]
    let history: [HistoryItem]
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L10n.t("输入网址或搜索词", "Search or type a URL"), text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($isFocused)
                        .onSubmit {
                            onSubmit(text)
                        }
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)

                List {
                    let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let matchedBM = bookmarks.filter { $0.type != "folder" && (q.isEmpty || $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)) }.prefix(5)
                    let matchedHist = history.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }.prefix(8)

                    if !matchedBM.isEmpty {
                        Section(L10n.t("云端书签", "Bookmarks")) {
                            ForEach(Array(matchedBM)) { bm in
                                Button { onSubmit(bm.url) } label: {
                                    Label {
                                        VStack(alignment: .leading) {
                                            Text(bm.title).lineLimit(1)
                                            Text(bm.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    } icon: {
                                        Image(systemName: "bookmark.fill").foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }

                    if !matchedHist.isEmpty {
                        Section(L10n.t("最近浏览", "History")) {
                            ForEach(Array(matchedHist)) { h in
                                Button { onSubmit(h.url) } label: {
                                    Label {
                                        VStack(alignment: .leading) {
                                            Text(h.title).lineLimit(1)
                                            Text(h.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    } icon: {
                                        Image(systemName: "clock").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 12)
            .navigationTitle(L10n.t("地址与搜索", "Navigate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) { dismiss() }
                }
            }
            .onAppear { isFocused = true }
        }
    }
}

private struct VideoMiniStrip: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var handoffService: HandoffService
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    let onOpenSniffer: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                tab.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('pip');", completionHandler: nil)
            } label: {
                Label(L10n.t("画中画", "PiP"), systemImage: "pip.enter")
            }

            Menu {
                ForEach([1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { rate in
                    Button("\(String(format: "%.2gx", rate))") {
                        tab.playbackRate = rate
                        tab.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('rate', \(rate));", completionHandler: nil)
                    }
                }
            } label: {
                Text("\(String(format: "%.2gx", tab.playbackRate))")
            }

            if !tab.sniffedMedia.isEmpty {
                Button(action: onOpenSniffer) {
                    Label(L10n.t("保存(\(tab.sniffedMedia.count))", "Save(\(tab.sniffedMedia.count))"), systemImage: "arrow.down.circle.fill")
                }
            }

            if syncEngine.loggedIn {
                Button {
                    Task {
                        let ok = await handoffService.push(kind: "video", title: tab.title, url: tab.urlString, videoSeconds: tab.videoSeconds, syncEngine: syncEngine)
                        tabManager.showToast(ok ? L10n.t("已带进度接力至桌面端", "Sent video to desktop") : L10n.t("发送失败", "Failed"))
                    }
                } label: {
                    Label(L10n.t("桌面续播", "Desktop"), systemImage: "laptopcomputer")
                }
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "key.fill").foregroundStyle(.indigo)
            Text(L10n.t("保存密码并零知识云同步？", "Save & sync password?"))
                .font(.caption.weight(.medium))
            Spacer()
            Button(L10n.t("保存", "Save"), action: onSave)
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
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("来自桌面端接力", "Desktop Handoff"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(payload.title ?? payload.url ?? payload.text ?? "")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            Spacer()
            Button(L10n.t("打开", "Open"), action: onOpen)
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
