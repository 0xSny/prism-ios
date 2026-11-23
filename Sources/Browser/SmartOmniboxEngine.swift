import Foundation

struct OmniboxCandidateEntry: Identifiable {
    let id: String
    let title: String
    let url: String
    let subtitle: String
    let isBookmark: Bool
    let tabId: UUID?
    let score: Double
    let visitedAt: Double
    let accentHex: String?
}

struct QuickWebsiteSearchMatch: Equatable {
    let siteName: String
    let query: String
    let urlString: String
    let host: String
    let accentHex: String
}

struct InstantAnswerResult: Equatable {
    enum Kind: Equatable {
        case calculator
        case converter
        case color(hex: String, r: Int, g: Int, b: Int)
        case timestamp
    }

    let kind: Kind
    let primaryText: String
    let secondaryText: String
    let copyValue: String
}

struct BuiltinSiteEntry {
    let domain: String
    let url: String
    let title: String
    let aliases: [String]
    let searchTemplate: String?
    let bang: String?
    let accentHex: String
}

@MainActor
final class SmartOmniboxEngine: ObservableObject {
    static let shared = SmartOmniboxEngine()

    @Published private(set) var recentSearches: [String] = []

    private static let recentSearchesKey = "prism.recentSearches.v1"
    private static let maxRecentSearches = 8

    // In-memory LRU-like cache for CFStringTransform pinyin conversion (zero allocation churn during typing)
    private var pinyinCache: [String: (full: String, initials: String)] = [:]

    static let popularSites: [BuiltinSiteEntry] = [
        BuiltinSiteEntry(domain: "google.com", url: "https://www.google.com", title: "Google", aliases: ["g", "gg", "google", "谷歌"], searchTemplate: "https://www.google.com/search?q={q}", bang: "!g", accentHex: "#4285F4"),
        BuiltinSiteEntry(domain: "bing.com", url: "https://www.bing.com", title: "Bing 必应", aliases: ["b", "bing", "必应", "biying"], searchTemplate: "https://www.bing.com/search?q={q}", bang: "!b", accentHex: "#008373"),
        BuiltinSiteEntry(domain: "baidu.com", url: "https://www.baidu.com", title: "百度", aliases: ["bd", "baidu", "百度"], searchTemplate: "https://www.baidu.com/s?wd={q}", bang: "!bd", accentHex: "#2932E1"),
        BuiltinSiteEntry(domain: "duckduckgo.com", url: "https://duckduckgo.com", title: "DuckDuckGo", aliases: ["ddg", "duck", "duckduckgo"], searchTemplate: "https://duckduckgo.com/?q={q}", bang: "!ddg", accentHex: "#DE5833"),
        BuiltinSiteEntry(domain: "github.com", url: "https://github.com", title: "GitHub", aliases: ["gh", "git", "github"], searchTemplate: "https://github.com/search?q={q}", bang: "!gh", accentHex: "#24292F"),
        BuiltinSiteEntry(domain: "bilibili.com", url: "https://www.bilibili.com", title: "哔哩哔哩 Bilibili", aliases: ["bili", "blbl", "b站", "bilibili", "哔哩哔哩"], searchTemplate: "https://search.bilibili.com/all?keyword={q}", bang: "!bili", accentHex: "#FB7299"),
        BuiltinSiteEntry(domain: "zhihu.com", url: "https://www.zhihu.com", title: "知乎", aliases: ["zh", "zhihu", "知乎"], searchTemplate: "https://www.zhihu.com/search?type=content&q={q}", bang: "!zh", accentHex: "#0066FF"),
        BuiltinSiteEntry(domain: "youtube.com", url: "https://www.youtube.com", title: "YouTube", aliases: ["yt", "ytb", "youtube", "油管"], searchTemplate: "https://www.youtube.com/results?search_query={q}", bang: "!yt", accentHex: "#FF0000"),
        BuiltinSiteEntry(domain: "xiaohongshu.com", url: "https://www.xiaohongshu.com", title: "小红书", aliases: ["xhs", "xiaohongshu", "小红书", "red"], searchTemplate: "https://www.xiaohongshu.com/search_result?keyword={q}", bang: "!xhs", accentHex: "#FF2442"),
        BuiltinSiteEntry(domain: "v2ex.com", url: "https://www.v2ex.com", title: "V2EX", aliases: ["v2", "v2ex"], searchTemplate: "https://www.google.com/search?q=site:v2ex.com+{q}", bang: "!v2", accentHex: "#333344"),
        BuiltinSiteEntry(domain: "linux.do", url: "https://linux.do", title: "LINUX DO", aliases: ["ld", "linuxdo", "linux.do"], searchTemplate: "https://linux.do/search?q={q}", bang: "!ld", accentHex: "#1E293B"),
        BuiltinSiteEntry(domain: "nodeseek.com", url: "https://www.nodeseek.com", title: "NodeSeek", aliases: ["ns", "nodeseek"], searchTemplate: "https://www.nodeseek.com/search?q={q}", bang: "!ns", accentHex: "#2563EB"),
        BuiltinSiteEntry(domain: "chatgpt.com", url: "https://chatgpt.com", title: "ChatGPT", aliases: ["gpt", "chatgpt", "openai"], searchTemplate: "https://chatgpt.com/?q={q}", bang: "!gpt", accentHex: "#10A37F"),
        BuiltinSiteEntry(domain: "claude.ai", url: "https://claude.ai", title: "Claude", aliases: ["claude", "cl"], searchTemplate: nil, bang: nil, accentHex: "#D97757"),
        BuiltinSiteEntry(domain: "gemini.google.com", url: "https://gemini.google.com", title: "Gemini", aliases: ["gemini", "gem"], searchTemplate: nil, bang: nil, accentHex: "#4285F4"),
        BuiltinSiteEntry(domain: "deepseek.com", url: "https://chat.deepseek.com", title: "DeepSeek", aliases: ["ds", "deepseek", "深度求索"], searchTemplate: nil, bang: nil, accentHex: "#4D6BFE"),
        BuiltinSiteEntry(domain: "perplexity.ai", url: "https://www.perplexity.ai", title: "Perplexity", aliases: ["pplx", "perplexity"], searchTemplate: "https://www.perplexity.ai/search?q={q}", bang: "!p", accentHex: "#20808D"),
        BuiltinSiteEntry(domain: "taobao.com", url: "https://www.taobao.com", title: "淘宝", aliases: ["tb", "taobao", "淘宝"], searchTemplate: "https://s.taobao.com/search?q={q}", bang: "!tb", accentHex: "#FF5000"),
        BuiltinSiteEntry(domain: "jd.com", url: "https://www.jd.com", title: "京东", aliases: ["jd", "jingdong", "京东"], searchTemplate: "https://search.jd.com/Search?keyword={q}", bang: "!jd", accentHex: "#E1251B"),
        BuiltinSiteEntry(domain: "weibo.com", url: "https://weibo.com", title: "微博", aliases: ["wb", "weibo", "微博"], searchTemplate: "https://s.weibo.com/weibo?q={q}", bang: "!wb", accentHex: "#E6162D"),
        BuiltinSiteEntry(domain: "douban.com", url: "https://www.douban.com", title: "豆瓣", aliases: ["db", "douban", "豆瓣"], searchTemplate: "https://www.douban.com/search?q={q}", bang: "!db", accentHex: "#007722"),
        BuiltinSiteEntry(domain: "wikipedia.org", url: "https://zh.wikipedia.org", title: "Wikipedia 维基百科", aliases: ["wiki", "wikipedia", "维基", "维基百科"], searchTemplate: "https://zh.wikipedia.org/w/index.php?search={q}", bang: "!wiki", accentHex: "#6366F1"),
        BuiltinSiteEntry(domain: "reddit.com", url: "https://www.reddit.com", title: "Reddit", aliases: ["rd", "reddit"], searchTemplate: "https://www.reddit.com/search/?q={q}", bang: "!rd", accentHex: "#FF4500"),
        BuiltinSiteEntry(domain: "x.com", url: "https://x.com", title: "X (Twitter)", aliases: ["x", "tw", "twitter", "推特"], searchTemplate: "https://x.com/search?q={q}", bang: "!x", accentHex: "#111827"),
        BuiltinSiteEntry(domain: "stackoverflow.com", url: "https://stackoverflow.com", title: "Stack Overflow", aliases: ["so", "stackoverflow"], searchTemplate: "https://stackoverflow.com/search?q={q}", bang: "!so", accentHex: "#F48024"),
        BuiltinSiteEntry(domain: "developer.apple.com", url: "https://developer.apple.com", title: "Apple Developer", aliases: ["apple", "swift", "xcode"], searchTemplate: "https://developer.apple.com/search/?q={q}", bang: "!ap", accentHex: "#007AFF"),
        BuiltinSiteEntry(domain: "sspai.com", url: "https://sspai.com", title: "少数派", aliases: ["sspai", "少数派", "ssp"], searchTemplate: "https://sspai.com/search/post/{q}", bang: nil, accentHex: "#DA282A"),
        BuiltinSiteEntry(domain: "juejin.cn", url: "https://juejin.cn", title: "稀土掘金", aliases: ["jj", "juejin", "掘金"], searchTemplate: "https://juejin.cn/search?query={q}", bang: nil, accentHex: "#1E80FF"),
        BuiltinSiteEntry(domain: "csdn.net", url: "https://www.csdn.net", title: "CSDN", aliases: ["csdn"], searchTemplate: "https://so.csdn.net/so/search?q={q}", bang: nil, accentHex: "#FC5531"),
        BuiltinSiteEntry(domain: "jianshu.com", url: "https://www.jianshu.com", title: "简书", aliases: ["js", "jianshu", "简书"], searchTemplate: "https://www.jianshu.com/search?q={q}", bang: nil, accentHex: "#EA6F5A"),
        BuiltinSiteEntry(domain: "qq.com", url: "https://www.qq.com", title: "腾讯网", aliases: ["qq", "tencent", "腾讯"], searchTemplate: nil, bang: nil, accentHex: "#12B7F5"),
        BuiltinSiteEntry(domain: "v.qq.com", url: "https://v.qq.com", title: "腾讯视频", aliases: ["vqq", "txsp", "腾讯视频"], searchTemplate: "https://v.qq.com/x/search/?q={q}", bang: nil, accentHex: "#FF6A00"),
        BuiltinSiteEntry(domain: "iqiyi.com", url: "https://www.iqiyi.com", title: "爱奇艺", aliases: ["iqy", "iqiyi", "爱奇艺", "aqy"], searchTemplate: "https://www.iqiyi.com/search/{q}.html", bang: nil, accentHex: "#00BE06"),
        BuiltinSiteEntry(domain: "youku.com", url: "https://www.youku.com", title: "优酷", aliases: ["yk", "youku", "优酷"], searchTemplate: "https://so.youku.com/search_video/q_{q}", bang: nil, accentHex: "#0D9BFF"),
        BuiltinSiteEntry(domain: "music.163.com", url: "https://music.163.com", title: "网易云音乐", aliases: ["163", "wyy", "网易云"], searchTemplate: "https://music.163.com/#/search/m/?s={q}", bang: nil, accentHex: "#C20C0C"),
        BuiltinSiteEntry(domain: "douyin.com", url: "https://www.douyin.com", title: "抖音", aliases: ["dy", "douyin", "抖音"], searchTemplate: "https://www.douyin.com/search/{q}", bang: nil, accentHex: "#111827"),
        BuiltinSiteEntry(domain: "kuaishou.com", url: "https://www.kuaishou.com", title: "快手", aliases: ["ks", "kuaishou", "快手"], searchTemplate: "https://www.kuaishou.com/search/video?searchKey={q}", bang: nil, accentHex: "#FF4906"),
        BuiltinSiteEntry(domain: "pinduoduo.com", url: "https://mobile.yangkeduo.com", title: "拼多多", aliases: ["pdd", "pinduoduo", "拼多多"], searchTemplate: nil, bang: nil, accentHex: "#E02E24"),
        BuiltinSiteEntry(domain: "amazon.com", url: "https://www.amazon.com", title: "Amazon", aliases: ["amz", "amazon", "亚马逊"], searchTemplate: "https://www.amazon.com/s?k={q}", bang: "!amz", accentHex: "#FF9900"),
        BuiltinSiteEntry(domain: "notion.so", url: "https://www.notion.so", title: "Notion", aliases: ["notion"], searchTemplate: nil, bang: nil, accentHex: "#111827"),
        BuiltinSiteEntry(domain: "figma.com", url: "https://www.figma.com", title: "Figma", aliases: ["figma"], searchTemplate: nil, bang: nil, accentHex: "#A259FF"),
        BuiltinSiteEntry(domain: "cloudflare.com", url: "https://dash.cloudflare.com", title: "Cloudflare", aliases: ["cf", "cloudflare"], searchTemplate: nil, bang: nil, accentHex: "#F38020"),
        BuiltinSiteEntry(domain: "vercel.com", url: "https://vercel.com", title: "Vercel", aliases: ["vercel"], searchTemplate: nil, bang: nil, accentHex: "#111827"),
        BuiltinSiteEntry(domain: "npmjs.com", url: "https://www.npmjs.com", title: "npm", aliases: ["npm", "npmjs"], searchTemplate: "https://www.npmjs.com/search?q={q}", bang: "!npm", accentHex: "#CB3837"),
        BuiltinSiteEntry(domain: "pypi.org", url: "https://pypi.org", title: "PyPI", aliases: ["pypi"], searchTemplate: "https://pypi.org/search/?q={q}", bang: "!pypi", accentHex: "#3775A9"),
        BuiltinSiteEntry(domain: "hub.docker.com", url: "https://hub.docker.com", title: "Docker Hub", aliases: ["docker"], searchTemplate: "https://hub.docker.com/search?q={q}", bang: nil, accentHex: "#2496ED"),
        BuiltinSiteEntry(domain: "huggingface.co", url: "https://huggingface.co", title: "Hugging Face", aliases: ["hf", "huggingface"], searchTemplate: "https://huggingface.co/search/full-text?q={q}", bang: "!hf", accentHex: "#FFD21E")
    ]

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) {
            self.recentSearches = Array(saved.prefix(Self.maxRecentSearches))
        }
    }

    func recordSearchIfNeeded(_ rawInput: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !Self.isLikelyExplicitURL(trimmed),
              trimmed.count <= 80 else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > Self.maxRecentSearches {
            recentSearches = Array(recentSearches.prefix(Self.maxRecentSearches))
        }
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchesKey)
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.recentSearchesKey)
    }

    // MARK: - URL Classification

    static func isLikelyExplicitURL(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return false }
        let low = s.lowercased()
        if low.contains("://") || low.hasPrefix("localhost") || low.hasPrefix("127.0.0.1") {
            return true
        }
        if let dot = low.firstIndex(of: "."), dot != low.startIndex, dot < low.index(before: low.endIndex) {
            let afterDot = low[low.index(after: dot)...]
            if afterDot.contains(where: { $0.isLetter }) {
                return true
            }
        }
        return false
    }

    // MARK: - Pinyin + Fuzzy Indexing

    func pinyinTuple(for source: String) -> (full: String, initials: String) {
        if let cached = pinyinCache[source] {
            return cached
        }
        // Only transform if string contains non-ASCII letters (saves work on pure English titles)
        guard source.unicodeScalars.contains(where: { !$0.isASCII && CharacterSet.letters.contains($0) }) else {
            let clean = source.lowercased()
            let val = (clean, "")
            cachePinyin(key: source, value: val)
            return val
        }

        let mutable = NSMutableString(string: source) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let latin = (mutable as String).lowercased()

        let words = latin.split { !$0.isLetter && !$0.isNumber }
        let full = words.joined()
        let initials = String(words.compactMap(\.first))
        let val = (full, initials)
        cachePinyin(key: source, value: val)
        return val
    }

    private func cachePinyin(key: String, value: (full: String, initials: String)) {
        if pinyinCache.count > 1200 {
            pinyinCache.removeAll(keepingCapacity: true)
        }
        pinyinCache[key] = value
    }

    // MARK: - Quick Website Search

    static func parseQuickSiteSearch(_ rawInput: String) -> QuickWebsiteSearchMatch? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIdx = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let trigger = String(trimmed[..<spaceIdx]).lowercased()
        let keyword = String(trimmed[spaceIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !keyword.isEmpty else { return nil }

        // Match Bangs (!g, !b, !gh, !yt, !zh, !xhs, !bd, !ddg, etc.) or exact site aliases
        for site in popularSites {
            guard let template = site.searchTemplate else { continue }
            let hitBang = (site.bang?.lowercased() == trigger)
            let hitAlias = site.aliases.contains(where: { $0.lowercased() == trigger })
            if hitBang || hitAlias {
                let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
                let target = template.replacingOccurrences(of: "{q}", with: encoded)
                return QuickWebsiteSearchMatch(
                    siteName: site.title,
                    query: keyword,
                    urlString: target,
                    host: site.domain,
                    accentHex: site.accentHex
                )
            }
        }
        return nil
    }

    // MARK: - Five-Dimensional Candidate Ranking

    func buildCandidates(
        queryRaw: String,
        bookmarks: [BookmarkItem],
        history: [HistoryItem],
        tabs: [BrowserTab],
        activeTab: BrowserTab?,
        shortcuts: [HomeShortcut]
    ) -> (topHit: OmniboxCandidateEntry?, tabs: [OmniboxCandidateEntry], library: [OmniboxCandidateEntry]) {
        let trimmed = queryRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = trimmed.lowercased()
        let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<String>()
        let activeId = activeTab?.id
        let nowMs = Date().timeIntervalSince1970 * 1000.0

        if q.isEmpty {
            var tabEntries: [OmniboxCandidateEntry] = []
            for t in tabs where !t.isNewTab && t.id != activeId {
                let k = Self.normalizeKey(t.urlString)
                if seen.contains(k) { continue }
                seen.insert(k)
                let host = Self.hostOnly(t.urlString)
                tabEntries.append(OmniboxCandidateEntry(
                    id: "tab-\(t.id.uuidString)",
                    title: t.title.isEmpty ? host : t.title,
                    url: t.urlString,
                    subtitle: "\(host) · \(L10n.t("打开的标签页", "Open Tab"))",
                    isBookmark: false,
                    tabId: t.id,
                    score: 50,
                    visitedAt: 0,
                    accentHex: nil
                ))
                if tabEntries.count >= 4 { break }
            }
            var libEntries: [OmniboxCandidateEntry] = []
            for h in history {
                let k = Self.normalizeKey(h.url)
                if seen.contains(k) { continue }
                seen.insert(k)
                let host = Self.hostOnly(h.url)
                libEntries.append(OmniboxCandidateEntry(
                    id: "hist-\(h.id)",
                    title: h.title.isEmpty ? host : h.title,
                    url: h.url,
                    subtitle: "\(host) · \(Self.relativeTime(h.visitedAt))",
                    isBookmark: false,
                    tabId: nil,
                    score: 20,
                    visitedAt: h.visitedAt,
                    accentHex: nil
                ))
                if libEntries.count >= 6 { break }
            }
            for bm in bookmarks where bm.type != "folder" {
                if libEntries.count >= 10 { break }
                let k = Self.normalizeKey(bm.url)
                if seen.contains(k) { continue }
                seen.insert(k)
                let host = Self.hostOnly(bm.url)
                libEntries.append(OmniboxCandidateEntry(
                    id: "bm-\(bm.id)",
                    title: bm.title.isEmpty ? host : bm.title,
                    url: bm.url,
                    subtitle: "\(host) · \(L10n.t("书签", "Bookmark"))",
                    isBookmark: true,
                    tabId: nil,
                    score: 20,
                    visitedAt: bm.createdAt,
                    accentHex: nil
                ))
            }
            return (nil, tabEntries, libEntries)
        }

        // Aggregate history Frecency per normalized URL
        var visitStats: [String: (count: Int, latest: HistoryItem)] = [:]
        var rootVisitBoost: [String: Double] = [:]
        for h in history {
            let k = Self.normalizeKey(h.url)
            let ageDays = max(0.0, (nowMs - h.visitedAt) / 86_400_000.0)
            let decay = exp(-ageDays * 0.08)
            rootVisitBoost[Self.hostOnly(h.url), default: 0] += decay * 14.0
            if var cur = visitStats[k] {
                cur.count += 1
                if h.visitedAt > cur.latest.visitedAt { cur.latest = h }
                visitStats[k] = cur
            } else {
                visitStats[k] = (1, h)
            }
        }

        var scoredSites: [OmniboxCandidateEntry] = []
        var tabMatches: [OmniboxCandidateEntry] = []

        // 1. Open Tabs
        for t in tabs where !t.isNewTab {
            let s = scoreMatch(queryLower: q, tokens: tokens, title: t.title, url: t.urlString)
            if s > 0 {
                let host = Self.hostOnly(t.urlString)
                tabMatches.append(OmniboxCandidateEntry(
                    id: "tab-\(t.id.uuidString)",
                    title: t.title.isEmpty ? host : t.title,
                    url: t.urlString,
                    subtitle: "\(host) · \(L10n.t("打开的标签页", "Open Tab"))",
                    isBookmark: false,
                    tabId: t.id,
                    score: s + 8,
                    visitedAt: nowMs,
                    accentHex: nil
                ))
            }
        }
        tabMatches.sort { $0.score > $1.score }

        // 2. Bookmarks
        for bm in bookmarks where bm.type != "folder" {
            let s = scoreMatch(queryLower: q, tokens: tokens, title: bm.title, url: bm.url)
            if s > 0 {
                let host = Self.hostOnly(bm.url)
                let visits = visitStats[Self.normalizeKey(bm.url)]?.count ?? 0
                let frecencyBoost = min(40.0, Double(visits) * 6.0)
                scoredSites.append(OmniboxCandidateEntry(
                    id: "bm-\(bm.id)",
                    title: bm.title.isEmpty ? host : bm.title,
                    url: bm.url,
                    subtitle: "\(host) · \(L10n.t("书签", "Bookmark"))",
                    isBookmark: true,
                    tabId: nil,
                    score: s + 24 + frecencyBoost,
                    visitedAt: bm.createdAt,
                    accentHex: nil
                ))
            }
        }

        // 3. Home Shortcuts
        for sc in shortcuts {
            let s = scoreMatch(queryLower: q, tokens: tokens, title: sc.title, url: sc.url)
            if s > 0 {
                let host = Self.hostOnly(sc.url)
                scoredSites.append(OmniboxCandidateEntry(
                    id: "sc-\(sc.id)",
                    title: sc.title.isEmpty ? host : sc.title,
                    url: sc.url,
                    subtitle: "\(host) · \(L10n.t("常用快捷方式", "Favorite"))",
                    isBookmark: true,
                    tabId: nil,
                    score: s + 20,
                    visitedAt: 0,
                    accentHex: sc.color
                ))
            }
        }

        // 4. History (Frecency)
        for (_, stat) in visitStats {
            let h = stat.latest
            let s = scoreMatch(queryLower: q, tokens: tokens, title: h.title, url: h.url)
            if s > 0 {
                let host = Self.hostOnly(h.url)
                let ageDays = max(0.0, (nowMs - h.visitedAt) / 86_400_000.0)
                let frecency = min(55.0, Double(stat.count) * 8.0 * exp(-ageDays * 0.08))
                scoredSites.append(OmniboxCandidateEntry(
                    id: "hist-\(h.id)",
                    title: h.title.isEmpty ? host : h.title,
                    url: h.url,
                    subtitle: "\(host) · \(Self.relativeTime(h.visitedAt))",
                    isBookmark: false,
                    tabId: nil,
                    score: s + frecency,
                    visitedAt: h.visitedAt,
                    accentHex: nil
                ))
            }
        }

        // 5. Built-in 40+ Popular Sites Dictionary (helps zero-history users jump to major sites in 2 keystrokes)
        if !q.contains(" ") {
            for site in Self.popularSites {
                let aliasHit: Double = {
                    if site.aliases.contains(where: { $0.lowercased() == q }) { return 145 }
                    if site.aliases.contains(where: { $0.lowercased().hasPrefix(q) }) { return 112 }
                    if site.domain.hasPrefix(q) { return 115 }
                    return scoreMatch(queryLower: q, tokens: tokens, title: site.title, url: site.url)
                }()
                if aliasHit >= 80 {
                    let historyBoost = min(35.0, rootVisitBoost[Self.hostOnly(site.url)] ?? 0)
                    scoredSites.append(OmniboxCandidateEntry(
                        id: "popular-\(site.domain)",
                        title: site.title,
                        url: site.url,
                        subtitle: site.domain,
                        isBookmark: false,
                        tabId: nil,
                        score: aliasHit + historyBoost,
                        visitedAt: 0,
                        accentHex: site.accentHex
                    ))
                }
            }
        }

        scoredSites.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.visitedAt > $1.visitedAt
        }

        // 6. Safari Root-Domain Synthesis:
        // If best candidate is a deep subpage (e.g. github.com/0xSny/prism-ios) and query matches host prefix cleanly,
        // synthesize clean root domain https://github.com for Top Hit while preserving subpage in Library below!
        var topHit: OmniboxCandidateEntry? = nil
        if let best = scoredSites.first, best.score >= 85 {
            let host = Self.hostOnly(best.url)
            if !Self.isRootURL(best.url),
               q.count >= 2,
               !q.contains("/"),
               host.hasPrefix(q) || best.title.lowercased().hasPrefix(q),
               let parsed = URL(string: best.url),
               let scheme = parsed.scheme,
               let rawHost = parsed.host {
                let cleanRootURL = "\(scheme)://\(rawHost)"
                let cleanTitle = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
                topHit = OmniboxCandidateEntry(
                    id: "top-root-\(cleanTitle)",
                    title: cleanTitle.capitalized,
                    url: cleanRootURL,
                    subtitle: cleanTitle,
                    isBookmark: best.isBookmark,
                    tabId: nil,
                    score: best.score + 20,
                    visitedAt: best.visitedAt,
                    accentHex: best.accentHex
                )
                seen.insert(Self.normalizeKey(cleanRootURL))
            } else {
                topHit = OmniboxCandidateEntry(
                    id: "top-\(best.id)",
                    title: best.title,
                    url: best.url,
                    subtitle: host,
                    isBookmark: best.isBookmark,
                    tabId: nil,
                    score: best.score,
                    visitedAt: best.visitedAt,
                    accentHex: best.accentHex
                )
                seen.insert(Self.normalizeKey(best.url))
            }
        }

        var outTabs: [OmniboxCandidateEntry] = []
        for t in tabMatches where t.tabId != activeId {
            let k = Self.normalizeKey(t.url)
            if seen.contains(k) && topHit?.title.lowercased() == t.title.lowercased() { continue }
            outTabs.append(t)
            seen.insert(k)
            if outTabs.count >= 2 { break }
        }

        var outLib: [OmniboxCandidateEntry] = []
        for item in scoredSites {
            let k = Self.normalizeKey(item.url)
            if seen.contains(k) { continue }
            seen.insert(k)
            outLib.append(item)
            if outLib.count >= 6 { break }
        }

        return (topHit, outTabs, outLib)
    }

    private func scoreMatch(queryLower: String, tokens: [String], title: String, url: String) -> Double {
        let titleLow = title.lowercased()
        let urlLow = url.lowercased()
        let hostLow = Self.hostOnly(url)
        let py = pinyinTuple(for: title)

        for tok in tokens {
            let asciiMatch = titleLow.contains(tok) || urlLow.contains(tok)
            let pinyinMatch = !py.full.isEmpty && (py.full.contains(tok) || py.initials.contains(tok))
            if !asciiMatch && !pinyinMatch {
                return 0
            }
        }

        var score: Double = 15
        if hostLow == queryLower || titleLow == queryLower || (!py.full.isEmpty && py.full == queryLower) {
            score += 135
        } else if hostLow.hasPrefix(queryLower) {
            score += 105
        } else if titleLow.hasPrefix(queryLower) {
            score += 90
        } else if !py.initials.isEmpty && py.initials.hasPrefix(queryLower) && queryLower.count >= 2 {
            score += 88
        } else if !py.full.isEmpty && py.full.hasPrefix(queryLower) && queryLower.count >= 2 {
            score += 82
        } else if urlLow.contains("://\(queryLower)") || urlLow.contains(".\(queryLower)") {
            score += 62
        } else if titleLow.contains(queryLower) || (!py.full.isEmpty && py.full.contains(queryLower)) {
            score += 38
        } else if urlLow.contains(queryLower) {
            score += 25
        }

        if Self.isRootURL(url) && score >= 95 {
            score += 45
        }
        return score
    }

    // MARK: - String URL Helpers

    static func normalizeKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let host = hostOnly(trimmed)
        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            if let slashIdx = afterScheme.firstIndex(of: "/") {
                let tail = String(afterScheme[slashIdx...])
                return tail == "/" ? host : "\(host)\(tail)"
            }
            if let qIdx = afterScheme.firstIndex(of: "?") {
                return "\(host)\(afterScheme[qIdx...])"
            }
            return host
        }
        return trimmed.lowercased()
    }

    static func isRootURL(_ raw: String) -> Bool {
        guard let schemeRange = raw.range(of: "://") else { return false }
        let afterScheme = raw[schemeRange.upperBound...]
        if afterScheme.contains("?") { return false }
        guard let slashIdx = afterScheme.firstIndex(of: "/") else { return true }
        return slashIdx == afterScheme.index(before: afterScheme.endIndex)
    }

    static func hostOnly(_ raw: String) -> String {
        let s: Substring
        if let schemeRange = raw.range(of: "://") {
            s = raw[schemeRange.upperBound...]
        } else {
            s = Substring(raw)
        }
        let end = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == ":" }) ?? s.endIndex
        var host = String(s[..<end]).lowercased()
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host.isEmpty ? raw : host
    }

    static func relativeTime(_ visitedAtMs: Double) -> String {
        let sec = max(0, Date().timeIntervalSince1970 - visitedAtMs / 1000.0)
        if sec < 60 { return L10n.t("刚刚曾访问", "Just now") }
        let mins = Int(sec / 60)
        if mins < 60 { return L10n.t("\(mins)分钟前", "\(mins)m ago") }
        let hours = Int(sec / 3600)
        if hours < 24 { return L10n.t("\(hours)小时前", "\(hours)h ago") }
        let days = Int(sec / 86400)
        if days < 14 { return L10n.t("\(days)天前", "\(days)d ago") }
        let weeks = Int(days / 7)
        return L10n.t("\(weeks)周前", "\(weeks)w ago")
    }

    // MARK: - Spotlight Instant Answers (Math, Units, Temp, Color, Unix Timestamp)

    static func evaluateInstantAnswer(_ raw: String) -> InstantAnswerResult? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }

        if let color = evaluateColor(trimmed) { return color }
        if let ts = evaluateTimestamp(trimmed) { return ts }
        if let conv = evaluateUnitConversion(trimmed) { return conv }
        if let math = evaluateMathExpression(trimmed) {
            return InstantAnswerResult(
                kind: .calculator,
                primaryText: "= \(math)",
                secondaryText: L10n.t("数学计算 · 轻点复制结果", "Calculator · Tap to copy"),
                copyValue: math
            )
        }
        return nil
    }

    private static func evaluateColor(_ raw: String) -> InstantAnswerResult? {
        // #RRGGBB or #RGB
        if raw.hasPrefix("#") {
            let hex = String(raw.dropFirst())
            let expanded: String
            if hex.count == 3, hex.allSatisfy(\.isHexDigit) {
                expanded = hex.map { "\($0)\($0)" }.joined()
            } else if hex.count == 6, hex.allSatisfy(\.isHexDigit) {
                expanded = hex
            } else {
                return nil
            }
            guard let rgb = Int(expanded, radix: 16) else { return nil }
            let r = (rgb >> 16) & 0xFF
            let g = (rgb >> 8) & 0xFF
            let b = rgb & 0xFF
            let normHex = "#\(expanded.uppercased())"
            let rgbStr = "rgb(\(r), \(g), \(b))"
            return InstantAnswerResult(
                kind: .color(hex: normHex, r: r, g: g, b: b),
                primaryText: "\(normHex)  ·  \(rgbStr)",
                secondaryText: L10n.t("颜色预览 · 轻点复制色值", "Color Preview · Tap to copy"),
                copyValue: normHex
            )
        }

        // rgb(r, g, b)
        let low = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if low.hasPrefix("rgb(") && low.hasSuffix(")") {
            let inner = String(low.dropFirst(4).dropLast())
            let parts = inner.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
            let hexStr = String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
            return InstantAnswerResult(
                kind: .color(hex: hexStr, r: parts[0], g: parts[1], b: parts[2]),
                primaryText: "\(hexStr)  ·  rgb(\(parts[0]), \(parts[1]), \(parts[2]))",
                secondaryText: L10n.t("颜色预览 · 轻点复制 Hex", "Color Preview · Tap to copy"),
                copyValue: hexStr
            )
        }
        return nil
    }

    private static func evaluateTimestamp(_ raw: String) -> InstantAnswerResult? {
        guard (raw.count == 10 || raw.count == 13), raw.allSatisfy(\.isNumber),
              let num = Double(raw) else { return nil }
        let sec = (raw.count == 13) ? (num / 1000.0) : num
        // Valid window: 2000-01-01 to 2050-01-01
        guard sec >= 946_684_800 && sec <= 2_524_608_000 else { return nil }
        let date = Date(timeIntervalSince1970: sec)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = .current
        let localStr = fmt.string(from: date)
        return InstantAnswerResult(
            kind: .timestamp,
            primaryText: localStr,
            secondaryText: L10n.t("Unix 时间戳 (\(raw.count == 13 ? "毫秒" : "秒")) · 轻点复制", "Unix Timestamp · Tap to copy"),
            copyValue: localStr
        )
    }

    private static func evaluateUnitConversion(_ raw: String) -> InstantAnswerResult? {
        let cleaned = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^(-?\d+(?:\.\d+)?)\s*([a-zA-Z°]+)(?:\s+(?:to|in|=|->)\s+([a-zA-Z°]+))?$"#),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let valRange = Range(match.range(at: 1), in: cleaned),
              let srcRange = Range(match.range(at: 2), in: cleaned),
              let val = Double(cleaned[valRange]) else {
            return nil
        }

        let src = normalizeUnit(String(cleaned[srcRange]))
        let dstRaw: String? = (match.range(at: 3).location != NSNotFound)
            ? Range(match.range(at: 3), in: cleaned).map { normalizeUnit(String(cleaned[$0])) }
            : nil

        // 1. Temperature
        if src == "c" || src == "f" {
            let target = dstRaw ?? (src == "c" ? "f" : "c")
            guard (src == "c" && target == "f") || (src == "f" && target == "c") else { return nil }
            let out = (src == "c") ? (val * 9.0 / 5.0 + 32.0) : ((val - 32.0) * 5.0 / 9.0)
            let formatted = formatNumber(out)
            let suffix = target.uppercased()
            return InstantAnswerResult(
                kind: .converter,
                primaryText: "\(formatted) °\(suffix)",
                secondaryText: "\(formatNumber(val)) °\(src.uppercased()) = \(formatted) °\(suffix)",
                copyValue: "\(formatted)°\(suffix)"
            )
        }

        // 2. Length (meters base)
        let lengthToMeters: [String: Double] = [
            "mm": 0.001, "cm": 0.01, "m": 1.0, "km": 1000.0,
            "inch": 0.0254, "ft": 0.3048, "yd": 0.9144, "mi": 1609.344
        ]
        if let srcFactor = lengthToMeters[src] {
            let defaultTarget: [String: String] = [
                "inch": "cm", "ft": "m", "yd": "m", "mi": "km",
                "cm": "inch", "mm": "inch", "m": "ft", "km": "mi"
            ]
            let target = dstRaw ?? defaultTarget[src] ?? "cm"
            guard let dstFactor = lengthToMeters[target], target != src else { return nil }
            let out = (val * srcFactor) / dstFactor
            let formatted = formatNumber(out)
            return InstantAnswerResult(
                kind: .converter,
                primaryText: "\(formatted) \(target)",
                secondaryText: "\(formatNumber(val)) \(src) = \(formatted) \(target)",
                copyValue: "\(formatted) \(target)"
            )
        }

        // 3. Weight (grams base)
        let weightToGrams: [String: Double] = [
            "g": 1.0, "kg": 1000.0, "lb": 453.59237, "oz": 28.3495231
        ]
        if let srcFactor = weightToGrams[src] {
            let target = dstRaw ?? (src == "lb" || src == "oz" ? "kg" : "lb")
            guard let dstFactor = weightToGrams[target], target != src else { return nil }
            let out = (val * srcFactor) / dstFactor
            let formatted = formatNumber(out)
            return InstantAnswerResult(
                kind: .converter,
                primaryText: "\(formatted) \(target)",
                secondaryText: "\(formatNumber(val)) \(src) = \(formatted) \(target)",
                copyValue: "\(formatted) \(target)"
            )
        }

        // 4. Data storage (bytes base, binary 1024)
        let dataToBytes: [String: Double] = [
            "b": 1.0, "kb": 1024.0, "mb": 1_048_576.0, "gb": 1_073_741_824.0, "tb": 1_099_511_627_776.0
        ]
        if let srcFactor = dataToBytes[src] {
            let defaultData: [String: String] = ["kb": "mb", "mb": "gb", "gb": "mb", "tb": "gb", "b": "kb"]
            let target = dstRaw ?? defaultData[src] ?? "gb"
            guard let dstFactor = dataToBytes[target], target != src else { return nil }
            let out = (val * srcFactor) / dstFactor
            let formatted = formatNumber(out)
            return InstantAnswerResult(
                kind: .converter,
                primaryText: "\(formatted) \(target.uppercased())",
                secondaryText: "\(formatNumber(val)) \(src.uppercased()) = \(formatted) \(target.uppercased())",
                copyValue: "\(formatted) \(target.uppercased())"
            )
        }

        return nil
    }

    private static func normalizeUnit(_ raw: String) -> String {
        switch raw.replacingOccurrences(of: "°", with: "") {
        case "in", "inch", "inches": return "inch"
        case "foot", "feet", "ft": return "ft"
        case "yard", "yards", "yd": return "yd"
        case "mile", "miles", "mi": return "mi"
        case "lbs", "lb", "pound", "pounds": return "lb"
        case "ounce", "ounces", "oz": return "oz"
        case "celsius", "c": return "c"
        case "fahrenheit", "f": return "f"
        default: return raw.replacingOccurrences(of: "°", with: "")
        }
    }

    private static func evaluateMathExpression(_ raw: String) -> String? {
        let s = raw
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
        guard s.count >= 3 && s.count <= 64 else { return nil }
        var hasOperator = false
        var hasDigit = false
        for ch in s {
            if ch.isNumber {
                hasDigit = true
            } else if ch == "+" || ch == "-" || ch == "*" || ch == "/" || ch == "%" || ch == "^" {
                hasOperator = true
            } else if ch == "." || ch == "(" || ch == ")" || ch == " " {
                continue
            } else {
                return nil
            }
        }
        guard hasDigit && hasOperator else { return nil }
        let chars = Array(s.filter { $0 != " " })
        var idx = 0

        func parseExpr() -> Double? {
            guard var val = parseTerm() else { return nil }
            while idx < chars.count {
                let op = chars[idx]
                guard op == "+" || op == "-" else { break }
                idx += 1
                guard let rhs = parseTerm() else { return nil }
                val = (op == "+") ? (val + rhs) : (val - rhs)
            }
            return val
        }

        func parseTerm() -> Double? {
            guard var val = parsePower() else { return nil }
            while idx < chars.count {
                let op = chars[idx]
                guard op == "*" || op == "/" || op == "%" else { break }
                idx += 1
                guard let rhs = parsePower() else { return nil }
                if op == "*" {
                    val *= rhs
                } else {
                    if rhs == 0 { return nil }
                    val = (op == "/") ? (val / rhs) : val.truncatingRemainder(dividingBy: rhs)
                }
            }
            return val
        }

        func parsePower() -> Double? {
            guard let base = parseFactor() else { return nil }
            if idx < chars.count && chars[idx] == "^" {
                idx += 1
                guard let expVal = parsePower() else { return nil }
                return pow(base, expVal)
            }
            return base
        }

        func parseFactor() -> Double? {
            guard idx < chars.count else { return nil }
            if chars[idx] == "+" {
                idx += 1
                return parseFactor()
            }
            if chars[idx] == "-" {
                idx += 1
                guard let inner = parseFactor() else { return nil }
                return -inner
            }
            if chars[idx] == "(" {
                idx += 1
                guard let inner = parseExpr(), idx < chars.count, chars[idx] == ")" else { return nil }
                idx += 1
                return inner
            }
            let start = idx
            var sawDot = false
            var sawDigit = false
            while idx < chars.count {
                let c = chars[idx]
                if c >= "0" && c <= "9" {
                    sawDigit = true
                    idx += 1
                } else if c == "." && !sawDot {
                    sawDot = true
                    idx += 1
                } else {
                    break
                }
            }
            guard sawDigit, let num = Double(String(chars[start..<idx])) else { return nil }
            return num
        }

        guard let result = parseExpr(), idx == chars.count, result.isFinite else { return nil }
        return formatNumber(result)
    }

    private static func formatNumber(_ val: Double) -> String {
        if val.rounded(.towardZero) == val && abs(val) < 1e15 {
            return String(Int64(val))
        }
        return String(format: "%.6f", val)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}
