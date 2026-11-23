import SwiftUI
import UIKit

@MainActor
private final class OmniboxRemoteSuggester: ObservableObject {
    @Published var suggestions: [String] = []
    private var fetchTask: Task<Void, Never>?
    private var lastKey = ""
    private var lruMap: [String: [String]] = [:]
    private var lruOrder: [String] = []
    private static let maxCacheEntries = 60

    func update(query: String, engine: SearchEngineOption) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.hasPrefix("localhost"),
              !trimmed.hasPrefix("127.0.0.1") else {
            fetchTask?.cancel()
            lastKey = ""
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        let key = "\(engine.rawValue)|\(trimmed.lowercased())"
        if key == lastKey { return }
        lastKey = key

        // 0ms instant hit on backspacing or repeated queries
        if let cached = lruMap[key] {
            fetchTask?.cancel()
            if suggestions != cached { suggestions = cached }
            return
        }

        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let items = await Self.fetchRemote(query: trimmed, engine: engine)
            guard !Task.isCancelled, let self else { return }
            self.storeLRU(key: key, items: items)
            if self.lastKey == key {
                self.suggestions = items
            }
        }
    }

    private func storeLRU(key: String, items: [String]) {
        if let idx = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(key)
        lruMap[key] = items
        if lruOrder.count > Self.maxCacheEntries {
            let evicted = lruOrder.removeFirst()
            lruMap.removeValue(forKey: evicted)
        }
    }

    nonisolated private static func fetchRemote(query: String, engine: SearchEngineOption) async -> [String] {
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

struct OmniboxInlineOverlay: View {
    @Binding var text: String
    let bookmarks: [BookmarkItem]
    let history: [HistoryItem]
    let tabs: [BrowserTab]
    let activeTab: BrowserTab?
    let shortcuts: [HomeShortcut]
    let searchEngine: SearchEngineOption
    @Binding var enterTopHitEnabled: Bool
    let hasClipboardWebURL: Bool
    let canFindInPage: Bool
    let onRefreshClipboardPattern: () -> Void
    let onSubmit: (String) -> Void
    let onSelectTab: (UUID) -> Void
    let onFindInPage: (String) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var smartEngine = SmartOmniboxEngine.shared
    @StateObject private var remoteSuggester = OmniboxRemoteSuggester()
    @State private var pageMatchCount: Int?
    @State private var findCountTask: Task<Void, Never>?
    @State private var keyboardHeight: CGFloat = 0
    @State private var isDismissing: Bool = false
    @State private var copiedCurrentURLFeedback = false
    @State private var copiedAnswerFeedback = false

    var body: some View {
        buildBody()
    }

    private func currentKeyboardOverlap(for endFrame: CGRect) -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let screenHeight = scene?.screen.bounds.height ?? UIScreen.main.bounds.height
        let safeBottom = scene?.windows.first { $0.isKeyWindow }?.safeAreaInsets.bottom ?? 0
        return max(0, screenHeight - endFrame.origin.y - safeBottom)
    }

    private func triggerSmoothClose(after action: @escaping () -> Void) {
        guard !isDismissing else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.24)) {
            isDismissing = true
            keyboardHeight = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            action()
        }
    }

    private func buildBody() -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = trimmed.lowercased()
        let quickSite = !trimmed.isEmpty ? SmartOmniboxEngine.parseQuickSiteSearch(trimmed) : nil
        let instantAnswer = !trimmed.isEmpty ? SmartOmniboxEngine.evaluateInstantAnswer(trimmed) : nil
        let ranked = smartEngine.buildCandidates(
            queryRaw: trimmed,
            bookmarks: bookmarks,
            history: history,
            tabs: tabs,
            activeTab: activeTab,
            shortcuts: shortcuts
        )
        let topHit = !q.isEmpty ? ranked.topHit : nil
        let matchedTabs = ranked.tabs
        let libraryItems = ranked.library
        let remoteList = buildRemoteSearchList(trimmed: trimmed, rawLower: q, remote: remoteSuggester.suggestions)
        let isExplicitURL = SmartOmniboxEngine.isLikelyExplicitURL(trimmed)
        let enterOpensTopHit = (quickSite == nil) && enterTopHitEnabled && !isExplicitURL && topHit != nil
        let preferGoKey = isExplicitURL || enterOpensTopHit || quickSite != nil

        return ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .opacity(isDismissing ? 0 : 1)
                .onTapGesture { triggerSmoothClose { onDismiss() } }

            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if q.isEmpty {
                            zeroInputStartContent(matchedTabs: matchedTabs, libraryItems: libraryItems)
                        } else {
                            activeQueryContent(
                                trimmed: trimmed,
                                q: q,
                                isExplicitURL: isExplicitURL,
                                quickSite: quickSite,
                                instantAnswer: instantAnswer,
                                topHit: topHit,
                                enterOpensTopHit: enterOpensTopHit,
                                matchedTabs: matchedTabs,
                                remoteList: remoteList,
                                libraryItems: libraryItems
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .opacity(isDismissing ? 0 : 1)
                .offset(y: isDismissing ? 16 : 0)

                // Docked Bottom Search Capsule + Circular [×] Cancel Button directly under Candidates
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        SelectableAddressBar(
                            text: $text,
                            placeholder: L10n.t("搜索或输入网址", "Search or enter website name"),
                            preferGoKey: preferGoKey,
                            onSubmit: { target in
                                let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !t.isEmpty else { return }
                                if let qs = SmartOmniboxEngine.parseQuickSiteSearch(t) {
                                    smartEngine.recordSearchIfNeeded(qs.query)
                                    triggerSmoothClose { onSubmit(qs.urlString) }
                                } else if enterTopHitEnabled && !SmartOmniboxEngine.isLikelyExplicitURL(t) && t.lowercased() == q,
                                          let hit = topHit {
                                    if let tid = hit.tabId {
                                        triggerSmoothClose { onSelectTab(tid) }
                                    } else {
                                        triggerSmoothClose { onSubmit(hit.url) }
                                    }
                                } else {
                                    smartEngine.recordSearchIfNeeded(t)
                                    triggerSmoothClose { onSubmit(t) }
                                }
                            },
                            onPasteAndGo: { target in
                                triggerSmoothClose { onSubmit(target) }
                            }
                        )
                        .frame(height: 24)
                        if !text.isEmpty {
                            Button {
                                text = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(
                        Capsule()
                            .fill(Color(.secondarySystemGroupedBackground))
                            .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
                    )
                    .overlay(
                        Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                    )

                    Button {
                        triggerSmoothClose { onDismiss() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Color(.secondarySystemGroupedBackground))
                                    .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
                            )
                            .overlay(
                                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, isDismissing ? 10 : max(10, keyboardHeight + 6))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard !isDismissing,
                  let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let overlap = currentKeyboardOverlap(for: endFrame)
            withAnimation(.interpolatingSpring(stiffness: 360, damping: 32)) {
                keyboardHeight = overlap
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.24)) {
                keyboardHeight = 0
            }
        }
        .onAppear {
            onRefreshClipboardPattern()
            remoteSuggester.update(query: text, engine: searchEngine)
            schedulePageMatchCount(text)
        }
        .onChange(of: text) { _, newValue in
            copiedAnswerFeedback = false
            remoteSuggester.update(query: newValue, engine: searchEngine)
            schedulePageMatchCount(newValue)
        }
    }

    // MARK: - Zero-Input Intelligent Start State

    @ViewBuilder
    private func zeroInputStartContent(
        matchedTabs: [OmniboxCandidateEntry],
        libraryItems: [OmniboxCandidateEntry]
    ) -> some View {
        // 1. Current Webpage Quick Card (Copy, Share, Edit URL)
        if let cur = activeTab, !cur.isNewTab, !cur.urlString.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    FaviconView(urlString: cur.urlString, title: cur.title, size: 30, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cur.title.isEmpty ? SmartOmniboxEngine.hostOnly(cur.urlString) : cur.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(cur.urlString)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button {
                        UIPasteboard.general.string = cur.urlString
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        copiedCurrentURLFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedCurrentURLFeedback = false
                        }
                    } label: {
                        Label(
                            copiedCurrentURLFeedback ? L10n.t("已复制", "Copied") : L10n.t("复制", "Copy"),
                            systemImage: copiedCurrentURLFeedback ? "checkmark" : "doc.on.doc"
                        )
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(copiedCurrentURLFeedback ? .green : .primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if let shareURL = URL(string: cur.urlString) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            BrowserRootView.presentSystemShareSheet(items: [shareURL])
                        } label: {
                            Label(L10n.t("分享", "Share"), systemImage: "square.and.arrow.up")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        text = cur.urlString
                    } label: {
                        Label(L10n.t("编辑网址", "Edit URL"), systemImage: "pencil")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .background(cardBackground)
        }

        // 2. Privacy-Safe Clipboard URL Quick-Go Bar
        if hasClipboardWebURL {
            Button {
                if let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    triggerSmoothClose { onSubmit(raw) }
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.14))
                            .frame(width: 28, height: 28)
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("粘贴并打开剪贴板链接", "Paste & Open Clipboard Link"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L10n.t("检测到剪贴板包含网页地址，轻点直接前往", "Web URL detected in clipboard"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(cardBackground)
            }
            .buttonStyle(.plain)
        }

        // 3. Favorite Shortcuts Icon Strip
        let sortedShortcuts = Array(shortcuts.sorted { $0.order < $1.order }.prefix(10))
        if !sortedShortcuts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(L10n.t("常用快捷方式", "Favorites"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(sortedShortcuts) { sc in
                            Button {
                                triggerSmoothClose { onSubmit(sc.url) }
                            } label: {
                                VStack(spacing: 6) {
                                    FaviconView(urlString: sc.url, title: sc.title, size: 38, cornerRadius: 10, accentHex: sc.color)
                                    Text(sc.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .frame(width: 54)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .background(cardBackground)
            }
        }

        // 4. Recent Searches Capsules (max 8)
        if !smartEngine.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionHeader(L10n.t("最近搜索", "Recent Searches"))
                    Spacer()
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        smartEngine.clearRecentSearches()
                    } label: {
                        Text(L10n.t("清空", "Clear"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(smartEngine.recentSearches, id: \.self) { term in
                            Button {
                                smartEngine.recordSearchIfNeeded(term)
                                triggerSmoothClose { onSubmit(term) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(term)
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(cardBackground)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }

        // 5. Open Tabs Preview
        if !matchedTabs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(L10n.t("打开的标签页", "Open Tabs"))
                insetGroupedCard(items: matchedTabs) { item in
                    Button {
                        if let tid = item.tabId {
                            triggerSmoothClose { onSelectTab(tid) }
                        } else {
                            triggerSmoothClose { onSubmit(item.url) }
                        }
                    } label: {
                        candidateRowContent(item: item, showBadge: nil, highlight: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // 6. Recent History / Bookmarks
        if !libraryItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(L10n.t("历史与书签", "History & Bookmarks"))
                insetGroupedCard(items: libraryItems) { item in
                    Button {
                        triggerSmoothClose { onSubmit(item.url) }
                    } label: {
                        candidateRowContent(item: item, showBadge: nil, highlight: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Active Typing Content (Safari Inset-Grouped)

    @ViewBuilder
    private func activeQueryContent(
        trimmed: String,
        q: String,
        isExplicitURL: Bool,
        quickSite: QuickWebsiteSearchMatch?,
        instantAnswer: InstantAnswerResult?,
        topHit: OmniboxCandidateEntry?,
        enterOpensTopHit: Bool,
        matchedTabs: [OmniboxCandidateEntry],
        remoteList: [String],
        libraryItems: [OmniboxCandidateEntry]
    ) -> some View {
        // A. Quick Website Search Card
        if let quickSite {
            Button {
                smartEngine.recordSearchIfNeeded(quickSite.query)
                triggerSmoothClose { onSubmit(quickSite.urlString) }
            } label: {
                HStack(spacing: 12) {
                    FaviconView(urlString: quickSite.urlString, title: quickSite.siteName, size: 28, cornerRadius: 7, accentHex: quickSite.accentHex)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("在 \(quickSite.siteName) 中搜索 “\(quickSite.query)”", "Search \(quickSite.siteName) for “\(quickSite.query)”"))
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(quickSite.host)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    enterBadge
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }

        // B. Spotlight Instant Answer Card (Math / Units / Color Swatch / Timestamp)
        if let answer = instantAnswer {
            Button {
                UIPasteboard.general.string = answer.copyValue
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                copiedAnswerFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    copiedAnswerFeedback = false
                }
            } label: {
                HStack(spacing: 12) {
                    instantAnswerIcon(answer.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(answer.primaryText)
                            .font(.system(size: 16.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(answer.secondaryText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if copiedAnswerFeedback {
                        Text(L10n.t("已复制", "Copied"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.14), in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(cardBackground)
            }
            .buttonStyle(.plain)
        }

        // C. Top Hit + Open Matching Tabs
        if topHit != nil || !matchedTabs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if topHit != nil {
                    HStack {
                        sectionHeader(L10n.t("最佳匹配", "Top Hit"))
                        Spacer()
                        if !isExplicitURL && quickSite == nil {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                enterTopHitEnabled.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: enterTopHitEnabled ? "return" : "magnifyingglass")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(enterTopHitEnabled
                                         ? L10n.t("回车直达：开", "Enter → Site: On")
                                         : L10n.t("回车直达：关", "Enter → Search"))
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(enterTopHitEnabled ? Color.blue : Color.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(enterTopHitEnabled ? Color.blue.opacity(0.12) : Color(.tertiarySystemFill))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(spacing: 0) {
                    if let hit = topHit {
                        Button {
                            if let tid = hit.tabId {
                                triggerSmoothClose { onSelectTab(tid) }
                            } else {
                                triggerSmoothClose { onSubmit(hit.url) }
                            }
                        } label: {
                            candidateRowContent(item: hit, showBadge: enterOpensTopHit ? "↵" : nil, highlight: enterOpensTopHit)
                        }
                        .buttonStyle(.plain)

                        if !matchedTabs.isEmpty {
                            Divider().padding(.leading, 48)
                        }
                    }

                    ForEach(Array(matchedTabs.enumerated()), id: \.element.id) { idx, item in
                        Button {
                            if let tid = item.tabId {
                                triggerSmoothClose { onSelectTab(tid) }
                            } else {
                                triggerSmoothClose { onSubmit(item.url) }
                            }
                        } label: {
                            candidateRowContent(item: item, showBadge: nil, highlight: false)
                        }
                        .buttonStyle(.plain)

                        if idx < matchedTabs.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(enterOpensTopHit ? Color.blue.opacity(0.32) : Color.clear, lineWidth: 1)
                )
            }
        }

        // D. Search Engine Suggestions (Safari Reverse-Bold)
        if !remoteList.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("\(searchEngine.title)\(L10n.t("搜索建议", " Suggestions"))")

                VStack(spacing: 0) {
                    ForEach(Array(remoteList.enumerated()), id: \.element) { idx, term in
                        let isDefaultSearchRow = (idx == 0 && !enterOpensTopHit && quickSite == nil)
                        HStack(spacing: 10) {
                            Button {
                                smartEngine.recordSearchIfNeeded(term)
                                triggerSmoothClose { onSubmit(term) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 14, weight: isDefaultSearchRow ? .semibold : .regular))
                                        .foregroundStyle(isDefaultSearchRow ? Color.blue : Color.secondary)
                                        .frame(width: 24, height: 24)
                                    reverseBoldSuggestionText(term: term, query: trimmed)
                                        .font(.system(size: 16))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if isDefaultSearchRow {
                                        enterBadge
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if term.lowercased() != q {
                                Button {
                                    text = term
                                } label: {
                                    Image(systemName: "arrow.up.left")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                        if idx < remoteList.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(cardBackground)
            }
        }

        // E. Bookmarks, History & Popular Matches
        if !libraryItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(L10n.t("书签与历史记录", "Bookmarks & History"))
                insetGroupedCard(items: libraryItems) { item in
                    Button {
                        triggerSmoothClose { onSubmit(item.url) }
                    } label: {
                        candidateRowContent(item: item, showBadge: nil, highlight: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // F. On This Page
        if canFindInPage && !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let countLabel: String = {
                    if let c = pageMatchCount {
                        return L10n.t("此页（\(c)个匹配项）", "On This Page (\(c) matches)")
                    }
                    return L10n.t("此页", "On This Page")
                }()
                sectionHeader(countLabel)

                Button {
                    triggerSmoothClose { onFindInPage(trimmed) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                        Text(L10n.t("在当前页查找“\(trimmed)”", "Find “\(trimmed)” on Page"))
                            .font(.system(size: 15.5))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(cardBackground)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Safari Shared UI Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground).opacity(0.94))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private var enterBadge: some View {
        Text("↵")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func insetGroupedCard<Row: View>(
        items: [OmniboxCandidateEntry],
        @ViewBuilder rowBuilder: @escaping (OmniboxCandidateEntry) -> Row
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                rowBuilder(item)
                if idx < items.count - 1 {
                    Divider().padding(.leading, 48)
                }
            }
        }
        .background(cardBackground)
    }

    private func candidateRowContent(item: OmniboxCandidateEntry, showBadge: String?, highlight: Bool) -> some View {
        HStack(spacing: 12) {
            if item.tabId != nil {
                Image(systemName: "macwindow")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(highlight ? Color.blue : Color.secondary)
                    .frame(width: 24, height: 24)
            } else {
                FaviconView(
                    urlString: item.url,
                    title: item.title,
                    size: 24,
                    cornerRadius: 6,
                    accentHex: item.accentHex
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15.5, weight: highlight ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let badge = showBadge {
                Text(badge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if item.tabId != nil {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func instantAnswerIcon(_ kind: InstantAnswerResult.Kind) -> some View {
        switch kind {
        case .color(_, let r, let g, let b):
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0))
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                )
        case .calculator:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: "equal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
            }
        case .converter:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.orange)
            }
        case .timestamp:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.purple.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: "clock.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.purple)
            }
        }
    }

    // Safari-style Reverse-Bold: typed query stays .secondary regular, predicted continuation becomes .primary bold
    private func reverseBoldSuggestionText(term: String, query: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let range = term.range(of: q, options: .caseInsensitive) else {
            return Text(term).foregroundStyle(.primary)
        }
        let before = String(term[..<range.lowerBound])
        let match = String(term[range])
        let after = String(term[range.upperBound...])
        return Text(before).fontWeight(.semibold).foregroundStyle(.primary)
            + Text(match).fontWeight(.regular).foregroundStyle(.secondary)
            + Text(after).fontWeight(.semibold).foregroundStyle(.primary)
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

    private func schedulePageMatchCount(_ raw: String) {
        findCountTask?.cancel()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canFindInPage, !q.isEmpty, let wv = activeTab?.webView else {
            pageMatchCount = nil
            return
        }
        findCountTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            let encoded = (try? JSONEncoder().encode(q)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let js = """
            (() => {
              const q = (\(encoded) || '').toLowerCase();
              if (!q || !document.body) return 0;
              const txt = (document.body.innerText || '').toLowerCase();
              let count = 0, pos = 0;
              while ((pos = txt.indexOf(q, pos)) !== -1) {
                count++; pos += q.length;
                if (count >= 999) break;
              }
              return count;
            })()
            """
            wv.evaluateJavaScript(js) { val, _ in
                if !Task.isCancelled {
                    pageMatchCount = val as? Int
                }
            }
        }
    }
}
