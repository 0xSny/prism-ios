import Foundation
import SwiftUI

enum AppLang: String, Codable, CaseIterable, Sendable {
    case zhCN = "zh-CN"
    case en = "en"
}

enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

enum SearchEngineOption: String, Codable, CaseIterable, Sendable {
    case google
    case bing
    case duckduckgo
    case baidu

    var title: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckduckgo: return "DuckDuckGo"
        case .baidu: return "Baidu"
        }
    }

    func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .google:
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .bing:
            return URL(string: "https://www.bing.com/search?q=\(encoded)")
        case .duckduckgo:
            return URL(string: "https://duckduckgo.com/?q=\(encoded)")
        case .baidu:
            return URL(string: "https://www.baidu.com/s?wd=\(encoded)")
        }
    }
}

enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case system
    case direct
    case custom
}

struct FingerprintConfig: Codable, Equatable, Sendable {
    var userAgent: String?
    var platform: String?
    var language: String?
    var timezone: String?
    var canvasNoise: Bool = false
    var blockTrackers: Bool = true
}

struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var color: String
    var partition: String
    var proxyMode: ProxyMode?
    var proxyRules: String
    var fingerprint: FingerprintConfig
    var createdAt: Double

    static let defaultProfile = BrowserProfile(
        id: "default",
        name: "默认身份",
        color: "#6366f1",
        partition: "persist:prism-default",
        proxyMode: .system,
        proxyRules: "",
        fingerprint: FingerprintConfig(canvasNoise: false, blockTrackers: true),
        createdAt: Date().timeIntervalSince1970 * 1000
    )

    var swiftColor: Color {
        Color(hex: color) ?? .indigo
    }
}

struct HomeShortcut: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var url: String
    var subtitle: String?
    var color: String?
    var favicon: String?
    var order: Int
}

struct WeatherLocationConfig: Codable, Equatable, Sendable {
    var name: String = "北京"
    var latitude: Double = 39.9042
    var longitude: Double = 116.4074
    var autoLocate: Bool = true
    var unit: String = "C" // "C" | "F"
}

struct HomeConfig: Codable, Equatable, Sendable {
    var showGreeting: Bool = false
    var showShortcuts: Bool = true
    var showProfileStatus: Bool = false
    var backgroundMode: String = "solid"
    var backgroundImageDataUrl: String?
    var themeAccentColor: String? = "#ffffff"
    var weatherLocation: WeatherLocationConfig? = WeatherLocationConfig()
    var shortcuts: [HomeShortcut] = HomeConfig.defaultShortcuts

    static let defaultShortcuts: [HomeShortcut] = [
        HomeShortcut(id: "sc-google", title: "Google", url: "https://www.google.com", color: "#4285F4", order: 0),
        HomeShortcut(id: "sc-youtube", title: "YouTube", url: "https://www.youtube.com", color: "#EF4444", order: 1),
        HomeShortcut(id: "sc-github", title: "GitHub", url: "https://github.com", color: "#24292F", order: 2),
        HomeShortcut(id: "sc-bilibili", title: "Bilibili", url: "https://www.bilibili.com", color: "#FB7299", order: 3),
        HomeShortcut(id: "sc-chatgpt", title: "ChatGPT", url: "https://chatgpt.com", color: "#10A37F", order: 4),
    ]
}

struct BookmarkItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var type: String? // "url" | "folder"
    var parentId: String?
    var order: Int?
    var title: String
    var url: String
    var favicon: String?
    var profileId: String?
    var createdAt: Double
    var updatedAt: Double?
}

struct HistoryItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var url: String
    var title: String
    var profileId: String
    var visitedAt: Double
}

struct PasswordEntry: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var origin: String
    var username: String
    var password: String
    var note: String?
    var createdAt: Double
    var updatedAt: Double
}

struct SyncScopeToggles: Codable, Equatable, Sendable {
    var passwords: Bool = true
    var bookmarks: Bool = true
    var home_shortcuts: Bool = true
    var history: Bool = true
    var profiles: Bool = true
    var settings: Bool = true
    var userscripts: Bool = true
    var plugins: Bool = true

    init(
        passwords: Bool = true,
        bookmarks: Bool = true,
        home_shortcuts: Bool = true,
        history: Bool = true,
        profiles: Bool = true,
        settings: Bool = true,
        userscripts: Bool = true,
        plugins: Bool = true
    ) {
        self.passwords = passwords
        self.bookmarks = bookmarks
        self.home_shortcuts = home_shortcuts
        self.history = history
        self.profiles = profiles
        self.settings = settings
        self.userscripts = userscripts
        self.plugins = plugins
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.passwords = try c.decodeIfPresent(Bool.self, forKey: .passwords) ?? true
        self.bookmarks = try c.decodeIfPresent(Bool.self, forKey: .bookmarks) ?? true
        self.home_shortcuts = try c.decodeIfPresent(Bool.self, forKey: .home_shortcuts) ?? true
        self.history = try c.decodeIfPresent(Bool.self, forKey: .history) ?? true
        self.profiles = try c.decodeIfPresent(Bool.self, forKey: .profiles) ?? true
        self.settings = try c.decodeIfPresent(Bool.self, forKey: .settings) ?? true
        self.userscripts = try c.decodeIfPresent(Bool.self, forKey: .userscripts) ?? true
        self.plugins = try c.decodeIfPresent(Bool.self, forKey: .plugins) ?? true
    }
}

struct UserscriptMeta: Codable, Equatable, Sendable {
    var name: String
    var namespace: String?
    var version: String
    var description: String
    var author: String?
    var icon: String?
    var matches: [String]
    var includes: [String]
    var excludes: [String]
    var grants: [String]
    var requires: [String]
    var resources: [String: String]
    var runAt: String // "document-start" | "document-body" | "document-end" | "document-idle"
    var noFrames: Bool
    var platforms: [String]? // ["desktop", "ios"]
    var downloadURL: String?
    var updateURL: String?
    var homepageURL: String?
}

struct UserscriptItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var enabled: Bool
    var disabledProfileIds: [String]?
    var sourceUrl: String?
    var code: String
    var meta: UserscriptMeta
    var createdAt: Double
    var updatedAt: Double
}

struct SidebarPluginManifest: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var icon: String?
    var permissions: [String]
    var platforms: [String]?
    var hostPermissions: [String]?
    var contextMenus: [String]?
}

struct SidebarPluginItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var enabled: Bool
    var disabledProfileIds: [String]?
    var manifest: SidebarPluginManifest
    var html: String
    var sourceType: String
    var sourceName: String?
    var createdAt: Double
    var updatedAt: Double
}

struct PortableSettings: Codable, Equatable, Sendable {
    var language: AppLang?
    var theme: AppTheme?
    var searchEngine: SearchEngineOption?
    var defaultProxyMode: String?
    var stripTrackingParams: Bool?
    var autoSyncIntervalMinutes: Int?
    var builtInAdblockEnabled: Bool?
    var blockRogueAppJumps: Bool?
    var omniboxEnterTopHitEnabled: Bool?
    var webDarkModeFollowTheme: Bool?
    var webDarkModeWhitelistHosts: [String]?
}

struct SyncItemPayload: Codable, Sendable {
    var scope: String
    var itemId: String
    var iv: String
    var ciphertext: String
    var tag: String
    var deleted: Bool
    var updatedAt: Double
}

struct EncryptedEnvelope: Codable, Sendable {
    var iv: String
    var ciphertext: String
    var tag: String
}

struct AccountSessionDisk: Codable {
    var serverUrl: String
    var token: String
    var email: String
    var userId: String
    var kdfSalt: String
    var deviceId: String
    var deviceName: String
    var lastSyncedAt: Double?
    var lastPulledAt: Double?
    var encKeyB64: String?
}

struct HandoffPayload: Identifiable, Codable, Equatable {
    var id: String
    var kind: String // "tab" | "video" | "clipboard" | "image"
    var type: String?
    var targetPlatform: String?
    var title: String?
    var url: String?
    var videoSeconds: Double?
    var text: String?
    var imageDataUrl: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var filename: String?
    var fromDeviceName: String?
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, type, targetPlatform, title, url, videoSeconds, text, imageDataUrl, imageWidth, imageHeight, filename, fromDeviceName, createdAt
    }

    init(
        id: String = UUID().uuidString,
        kind: String,
        type: String? = nil,
        targetPlatform: String? = nil,
        title: String? = nil,
        url: String? = nil,
        videoSeconds: Double? = nil,
        text: String? = nil,
        imageDataUrl: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        filename: String? = nil,
        fromDeviceName: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.id = id
        self.kind = kind
        self.type = type ?? kind
        self.targetPlatform = targetPlatform
        self.title = title
        self.url = url
        self.videoSeconds = videoSeconds
        self.text = text
        self.imageDataUrl = imageDataUrl
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.filename = filename
        self.fromDeviceName = fromDeviceName
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        let decodedKind = try container.decodeIfPresent(String.self, forKey: .kind)
        let decodedType = try container.decodeIfPresent(String.self, forKey: .type)
        self.kind = decodedKind ?? decodedType ?? "tab"
        self.type = decodedType ?? self.kind
        self.targetPlatform = try container.decodeIfPresent(String.self, forKey: .targetPlatform)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.videoSeconds = try container.decodeIfPresent(Double.self, forKey: .videoSeconds)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.imageDataUrl = try container.decodeIfPresent(String.self, forKey: .imageDataUrl)
        self.imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        self.imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
        self.filename = try container.decodeIfPresent(String.self, forKey: .filename)
        self.fromDeviceName = try container.decodeIfPresent(String.self, forKey: .fromDeviceName)
        self.createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? (Date().timeIntervalSince1970 * 1000)
    }
}

struct SniffedMediaItem: Identifiable, Equatable {
    let id = UUID()
    var url: String
    var mediaExt: String
    var title: String
    var pageUrl: String
    var timestamp: Date = Date()
}

struct ConsoleLogEntry: Identifiable, Equatable {
    let id = UUID()
    var level: String
    var message: String
    var timestamp: Date = Date()
}

struct NetworkLogEntry: Identifiable, Equatable {
    let id = UUID()
    var method: String
    var url: String
    var status: Int
    var durationMs: Int
    var timestamp: Date = Date()
}

struct ToastNotice: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var actionTitle: String?
    var urlToOpen: String?
    var handoff: HandoffPayload?
}

struct ReaderArticle: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var byline: String
    var siteHost: String
    var paragraphs: [String]
}

struct DownloadRecord: Identifiable, Equatable {
    let id: UUID
    var filename: String
    var sourceURL: String
    var localURL: URL?
    var byteCount: Int64
    var status: DownloadStatus
    var errorMessage: String?
    var createdAt: Date

    enum DownloadStatus: String, Equatable {
        case downloading
        case completed
        case failed
    }
}

extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&int) else { return nil }
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
