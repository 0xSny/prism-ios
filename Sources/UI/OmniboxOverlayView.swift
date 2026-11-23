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

// MARK: - iOS Liquid Glass Optical Modifier & Tactile ButtonStyle

private struct LiquidGlassBubbleModifier: ViewModifier {
    var isProminent: Bool = false
    var cornerRadius: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = (colorScheme == .dark)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fillColors: [Color] = isDark
            ? [
                Color.white.opacity(isProminent ? 0.13 : 0.08),
                Color.white.opacity(isProminent ? 0.05 : 0.03)
            ]
            : [
                Color.white.opacity(isProminent ? 0.90 : 0.88),
                Color.white.opacity(isProminent ? 0.76 : 0.70)
            ]
        let strokeColors: [Color] = isProminent
            ? (isDark
                ? [
                    Color(hex: "#60A5FA")?.opacity(0.70) ?? Color.blue.opacity(0.65),
                    Color.white.opacity(0.45),
                    Color(hex: "#A855F7")?.opacity(0.42) ?? Color.purple.opacity(0.4),
                    Color.white.opacity(0.12)
                ]
                : [
                    Color(hex: "#93C5FD")?.opacity(0.95) ?? Color.blue.opacity(0.6),
                    Color.white,
                    Color(hex: "#BAE6FD")?.opacity(0.85) ?? Color.cyan.opacity(0.5),
                    Color.white.opacity(0.80)
                ])
            : (isDark
                ? [
                    Color.white.opacity(0.38),
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.08)
                ]
                : [
                    Color.white,
                    Color.white.opacity(0.75),
                    Color.white.opacity(0.55)
                ])

        content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: fillColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    // Top inner specular highlight rim
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDark ? 0.28 : 0.96),
                                Color.white.opacity(isDark ? 0.04 : 0.25),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.0
                    )
                }
            )
            .clipShape(shape)
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: strokeColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isDark ? 1.0 : 1.2
                )
            )
            .shadow(
                color: isDark
                    ? Color.black.opacity(isProminent ? 0.36 : 0.24)
                    : Color(red: 0.08, green: 0.14, blue: 0.28).opacity(isProminent ? 0.13 : 0.08),
                radius: isProminent ? 16 : 11,
                x: 0,
                y: isProminent ? 6 : 4
            )
    }
}

private extension View {
    func liquidGlassBubble(isProminent: Bool = false, cornerRadius: CGFloat = 24) -> some View {
        modifier(LiquidGlassBubbleModifier(isProminent: isProminent, cornerRadius: cornerRadius))
    }
}

private struct LiquidGlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - Bottom-Up Floating Liquid Glass Omnibox Overlay

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

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var smartEngine = SmartOmniboxEngine.shared
    @StateObject private var remoteSuggester = OmniboxRemoteSuggester()
    @State private var pageMatchCount: Int?
    @State private var findCountTask: Task<Void, Never>?
    @State private var keyboardHeight: CGFloat = 0
    @State private var isDismissing: Bool = false
    @State private var copiedCurrentURLFeedback = false
    @State private var copiedAnswerFeedback = false
    @State private var baselinePrefilledText: String = ""
    @State private var userModifiedQuery: Bool = false
    @State private var cursorMoveNonce: Int = 0

    private enum PrimaryBubbleKind {
        case instantAnswer(InstantAnswerResult)
        case quickSite(QuickWebsiteSearchMatch)
        case topHit(OmniboxCandidateEntry)
        case searchPrimary(String)
    }

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
        let isDark = (colorScheme == .dark)
        let rawTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = userModifiedQuery ? rawTrimmed : ""
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
        let isExplicitURL = SmartOmniboxEngine.isLikelyExplicitURL(rawTrimmed)
        let enterOpensTopHit = (quickSite == nil) && enterTopHitEnabled && !isExplicitURL && topHit != nil
        let preferGoKey = isExplicitURL || enterOpensTopHit || quickSite != nil

        return ZStack(alignment: .bottom) {
            // Progressive Mist Scrim: Bright frosted white mist in Light Mode, soft vignette in Dark Mode
            LinearGradient(
                colors: isDark
                    ? [
                        Color.black.opacity(0.10),
                        Color.black.opacity(0.24),
                        Color.black.opacity(0.42)
                    ]
                    : [
                        Color.white.opacity(0.22),
                        Color.white.opacity(0.46),
                        Color.white.opacity(0.72)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .opacity(isDismissing ? 0 : 1)
            .onTapGesture { triggerSmoothClose { onDismiss() } }

            VStack(spacing: 0) {
                GeometryReader { scrollGeo in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            Spacer(minLength: 20)

                            if q.isEmpty {
                                zeroInputBottomUpStack(matchedTabs: matchedTabs)
                            } else {
                                activeQueryBottomUpStack(
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
                        .frame(maxWidth: .infinity, minHeight: scrollGeo.size.height, alignment: .bottom)
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                        .padding(.bottom, 10)
                        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: q)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.055),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .opacity(isDismissing ? 0 : 1)
                .offset(y: isDismissing ? 18 : 0)

                // Docked Liquid Glass Input Capsule + Circular [×] Dismiss Bubble
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                        SelectableAddressBar(
                            text: $text,
                            placeholder: L10n.t("搜索或输入网址", "Search or enter website name"),
                            preferGoKey: preferGoKey,
                            cursorMoveNonce: cursorMoveNonce,
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
                    .frame(height: 46)
                    .liquidGlassBubble(isProminent: false)

                    Button {
                        triggerSmoothClose { onDismiss() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .background(
                                ZStack {
                                    Circle().fill(.ultraThinMaterial)
                                    Circle().fill(
                                        LinearGradient(
                                            colors: isDark
                                                ? [Color.white.opacity(0.10), Color.white.opacity(0.04)]
                                                : [Color.white.opacity(0.90), Color.white.opacity(0.72)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                }
                            )
                            .overlay(
                                Circle().stroke(
                                    LinearGradient(
                                        colors: isDark
                                            ? [Color.white.opacity(0.45), Color.white.opacity(0.10)]
                                            : [Color.white, Color.white.opacity(0.60)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: isDark ? 1.0 : 1.2
                                )
                            )
                            .shadow(
                                color: isDark
                                    ? Color.black.opacity(0.24)
                                    : Color(red: 0.08, green: 0.14, blue: 0.28).opacity(0.09),
                                radius: 10,
                                y: 4
                            )
                    }
                    .buttonStyle(LiquidGlassPressStyle())
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
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
            baselinePrefilledText = text
            userModifiedQuery = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            onRefreshClipboardPattern()
            let initialQuery = userModifiedQuery ? text : ""
            remoteSuggester.update(query: initialQuery, engine: searchEngine)
            schedulePageMatchCount(initialQuery)
        }
        .onChange(of: text) { _, newValue in
            copiedAnswerFeedback = false
            if !userModifiedQuery && newValue != baselinePrefilledText {
                userModifiedQuery = true
            }
            let effectiveQuery = userModifiedQuery ? newValue : ""
            remoteSuggester.update(query: effectiveQuery, engine: searchEngine)
            schedulePageMatchCount(effectiveQuery)
        }
    }

    // MARK: - Zero-Input Bottom-Up Bubbles (Weakest Top -> #1 Strongest Bottom Above Input)

    @ViewBuilder
    private func zeroInputBottomUpStack(matchedTabs: [OmniboxCandidateEntry]) -> some View {
        // Upper bubble: Open Tabs
        ForEach(Array(matchedTabs.prefix(2).reversed())) { item in
            Button {
                if let tid = item.tabId {
                    triggerSmoothClose { onSelectTab(tid) }
                } else {
                    triggerSmoothClose { onSubmit(item.url) }
                }
            } label: {
                siteBubbleLabel(item: item, isProminent: false, showEnter: false)
            }
            .buttonStyle(LiquidGlassPressStyle())
        }

        // Upper bubble: Favorites Shortcut Strip
        let sortedShortcuts = Array(shortcuts.sorted { $0.order < $1.order }.prefix(8))
        if !sortedShortcuts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(sortedShortcuts) { sc in
                        Button {
                            triggerSmoothClose { onSubmit(sc.url) }
                        } label: {
                            VStack(spacing: 5) {
                                FaviconView(urlString: sc.url, title: sc.title, size: 32, cornerRadius: 9, accentHex: sc.color)
                                Text(sc.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 48)
                            }
                        }
                        .buttonStyle(LiquidGlassPressStyle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .liquidGlassBubble(isProminent: false)
        }

        // Mid bubble: Recent Searches enclosed in a bright Liquid Glass tray
        if !smartEngine.recentSearches.isEmpty {
            let isDark = (colorScheme == .dark)
            HStack(spacing: 8) {
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
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(
                                    Color.white.opacity(isDark ? 0.12 : 0.88),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().stroke(Color.white.opacity(isDark ? 0.14 : 0.92), lineWidth: 0.8)
                                )
                            }
                            .buttonStyle(LiquidGlassPressStyle())
                        }
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    smartEngine.clearRecentSearches()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Color.white.opacity(isDark ? 0.12 : 0.84),
                            in: Circle()
                        )
                }
                .buttonStyle(LiquidGlassPressStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .liquidGlassBubble(isProminent: false, cornerRadius: 20)
        }

        // Lower bubble (#2 or #1): Current Webpage Action Bubble (Copy / Share / Edit URL)
        if let cur = activeTab, !cur.isNewTab, !cur.urlString.isEmpty {
            HStack(spacing: 10) {
                FaviconView(urlString: cur.urlString, title: cur.title, size: 28, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cur.title.isEmpty ? SmartOmniboxEngine.hostOnly(cur.urlString) : cur.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(cur.urlString)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Button {
                        UIPasteboard.general.string = cur.urlString
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        copiedCurrentURLFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedCurrentURLFeedback = false
                        }
                    } label: {
                        Image(systemName: copiedCurrentURLFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(copiedCurrentURLFeedback ? .green : .primary)
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)

                    if let shareURL = URL(string: cur.urlString) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            BrowserRootView.presentSystemShareSheet(items: [shareURL])
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 32, height: 32)
                                .background(Color.primary.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        userModifiedQuery = true
                        cursorMoveNonce += 1
                        text = cur.urlString
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 32, height: 32)
                            .background(Color.blue.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .liquidGlassBubble(isProminent: !hasClipboardWebURL)
        }

        // Bottommost #1 (Right above input bar when clipboard has URL): Clipboard Quick-Go Bubble
        if hasClipboardWebURL {
            Button {
                if let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    triggerSmoothClose { onSubmit(raw) }
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.16))
                            .frame(width: 32, height: 32)
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("粘贴并打开剪贴板链接", "Paste & Open Clipboard Link"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L10n.t("检测到网页链接 · 轻点直达", "Web URL detected · Tap to go"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    enterBadge
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 54)
                .liquidGlassBubble(isProminent: true)
            }
            .buttonStyle(LiquidGlassPressStyle())
        }
    }

    // MARK: - Active Typing Bottom-Up Inverted Liquid Glass Stack
    // Visual Order (top to bottom -> weakest top, strongest #1 prominent bubble directly above thumb):
    //   On This Page Bubble -> Secondary Sites & Search Suggestions (decreasing downward rank) -> #1 Primary Action Bubble (height >= 54pt)

    @ViewBuilder
    private func activeQueryBottomUpStack(
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
        // Choose #1 Bottommost Primary Bubble: Instant Answer > Quick Site Search > Clean Top Hit > Engine Search Primary
        let primaryKind: PrimaryBubbleKind = {
            if let instantAnswer { return .instantAnswer(instantAnswer) }
            if let quickSite { return .quickSite(quickSite) }
            if let topHit { return .topHit(topHit) }
            return .searchPrimary(remoteList.first ?? trimmed)
        }()

        // Optional On-This-Page Find Bubble (topmost utility bubble)
        if canFindInPage && !trimmed.isEmpty {
            let countLabel = pageMatchCount.map { L10n.t("此页（\($0)个匹配）", "On Page (\($0) matches)") } ?? L10n.t("此页查找", "Find on Page")
            Button {
                triggerSmoothClose { onFindInPage(trimmed) }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                    Text("\(countLabel) “\(trimmed)”")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .liquidGlassBubble(isProminent: false)
            }
            .buttonStyle(LiquidGlassPressStyle())
        }

        // Open Tabs & Secondary Bookmarks/History (ordered weak top -> stronger downward)
        let secondarySites: [OmniboxCandidateEntry] = Array((matchedTabs + libraryItems).prefix(3)).reversed()
        ForEach(secondarySites) { item in
            Button {
                if let tid = item.tabId {
                    triggerSmoothClose { onSelectTab(tid) }
                } else {
                    triggerSmoothClose { onSubmit(item.url) }
                }
            } label: {
                siteBubbleLabel(item: item, isProminent: false, showEnter: false)
            }
            .buttonStyle(LiquidGlassPressStyle())
        }

        // Reverse-Bold Search Suggestions (ordered weak top -> strongest nearest thumb)
        let secondarySearchTerms: [String] = {
            if case .searchPrimary = primaryKind {
                return Array(remoteList.dropFirst().prefix(4)).reversed()
            } else {
                return Array(remoteList.prefix(3)).reversed()
            }
        }()
        ForEach(Array(secondarySearchTerms.enumerated()), id: \.element) { _, term in
            let isDefaultReturn = (term == (remoteList.first ?? trimmed)) && quickSite == nil && !enterOpensTopHit
            searchSuggestionBubble(term: term, trimmed: trimmed, q: q, isDefaultReturn: isDefaultReturn, isProminent: false)
        }

        // If #1 is Instant Answer or Quick Site Search, still keep Top Hit close at #2 if present!
        if case .instantAnswer = primaryKind, let hit = topHit {
            topHitBubble(hit: hit, isExplicitURL: isExplicitURL, enterOpensTopHit: enterOpensTopHit, isProminent: false)
        } else if case .quickSite = primaryKind, let hit = topHit {
            topHitBubble(hit: hit, isExplicitURL: isExplicitURL, enterOpensTopHit: false, isProminent: false)
        }

        // #1 Bottommost Gold-Thumb Primary Bubble (54pt+, directly above input capsule)
        switch primaryKind {
        case .instantAnswer(let answer):
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
                            .font(.system(size: 17, weight: .bold).monospacedDigit())
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
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.16), in: Capsule())
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 54)
                .liquidGlassBubble(isProminent: true)
            }
            .buttonStyle(LiquidGlassPressStyle())

        case .quickSite(let qs):
            Button {
                smartEngine.recordSearchIfNeeded(qs.query)
                triggerSmoothClose { onSubmit(qs.urlString) }
            } label: {
                HStack(spacing: 12) {
                    FaviconView(urlString: qs.urlString, title: qs.siteName, size: 28, cornerRadius: 8, accentHex: qs.accentHex)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("在 \(qs.siteName) 中搜索 “\(qs.query)”", "Search \(qs.siteName) for “\(qs.query)”"))
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(qs.host)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    enterBadge
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 54)
                .liquidGlassBubble(isProminent: true)
            }
            .buttonStyle(LiquidGlassPressStyle())

        case .topHit(let hit):
            topHitBubble(hit: hit, isExplicitURL: isExplicitURL, enterOpensTopHit: enterOpensTopHit, isProminent: true)

        case .searchPrimary(let term):
            searchSuggestionBubble(term: term, trimmed: trimmed, q: q, isDefaultReturn: true, isProminent: true)
        }
    }

    // MARK: - Individual Liquid Glass Bubble Components

    private func topHitBubble(hit: OmniboxCandidateEntry, isExplicitURL: Bool, enterOpensTopHit: Bool, isProminent: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if let tid = hit.tabId {
                    triggerSmoothClose { onSelectTab(tid) }
                } else {
                    triggerSmoothClose { onSubmit(hit.url) }
                }
            } label: {
                HStack(spacing: 12) {
                    FaviconView(urlString: hit.url, title: hit.title, size: isProminent ? 30 : 24, cornerRadius: 8, accentHex: hit.accentHex)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.title)
                            .font(.system(size: isProminent ? 16 : 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(hit.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isExplicitURL {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    enterTopHitEnabled.toggle()
                } label: {
                    Text(enterTopHitEnabled ? L10n.t("回车直达", "Enter → Go") : L10n.t("回车搜索", "Enter → Find"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(enterTopHitEnabled ? .blue : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            (enterTopHitEnabled ? Color.blue.opacity(0.14) : Color.primary.opacity(0.08)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            if enterOpensTopHit {
                enterBadge
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: isProminent ? 54 : 48)
        .liquidGlassBubble(isProminent: isProminent)
    }

    private func searchSuggestionBubble(term: String, trimmed: String, q: String, isDefaultReturn: Bool, isProminent: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                smartEngine.recordSearchIfNeeded(term)
                triggerSmoothClose { onSubmit(term) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: isDefaultReturn ? .semibold : .regular))
                        .foregroundStyle(isDefaultReturn ? .blue : .secondary)
                        .frame(width: 24, height: 24)
                    reverseBoldSuggestionText(term: term, query: trimmed)
                        .font(.system(size: isProminent ? 16 : 15))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isDefaultReturn {
                        enterBadge
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if term.lowercased() != q {
                Button {
                    userModifiedQuery = true
                    cursorMoveNonce += 1
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
        .padding(.horizontal, 14)
        .frame(minHeight: isProminent ? 54 : 46)
        .liquidGlassBubble(isProminent: isProminent)
    }

    private func siteBubbleLabel(item: OmniboxCandidateEntry, isProminent: Bool, showEnter: Bool) -> some View {
        HStack(spacing: 12) {
            if item.tabId != nil {
                Image(systemName: "macwindow")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.secondary)
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if showEnter {
                enterBadge
            } else if item.tabId != nil {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: isProminent ? 54 : 48)
        .liquidGlassBubble(isProminent: isProminent)
    }

    private var enterBadge: some View {
        Text("↵")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func instantAnswerIcon(_ kind: InstantAnswerResult.Kind) -> some View {
        switch kind {
        case .color(_, let r, let g, let b):
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0))
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.5), lineWidth: 1))
        case .calculator:
            ZStack {
                Circle().fill(Color.green.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: "equal").font(.system(size: 14, weight: .bold)).foregroundStyle(.green)
            }
        case .converter:
            ZStack {
                Circle().fill(Color.orange.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12.5, weight: .bold)).foregroundStyle(.orange)
            }
        case .timestamp:
            ZStack {
                Circle().fill(Color.purple.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: "clock.fill").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.purple)
            }
        }
    }

    private func reverseBoldSuggestionText(term: String, query: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return Text(term).foregroundStyle(.primary)
        }
        if term.caseInsensitiveCompare(q) == .orderedSame {
            return Text(term).fontWeight(.semibold).foregroundStyle(.primary)
        }
        guard let range = term.range(of: q, options: .caseInsensitive) else {
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
            let val = try? await wv.evaluateJavaScript(js)
            if !Task.isCancelled {
                pageMatchCount = val as? Int
            }
        }
    }
}
