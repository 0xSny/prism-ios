import Foundation
import SwiftUI

enum AppLang: String, Codable, CaseIterable {
    case zhCN = "zh-CN"
    case en = "en"
}

enum AppTheme: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

enum SearchEngineOption: String, Codable, CaseIterable {
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

enum ProxyMode: String, Codable, CaseIterable {
    case system
    case direct
    case custom
}

struct FingerprintConfig: Codable, Equatable {
    var userAgent: String?
    var platform: String?
    var language: String?
    var timezone: String?
    var canvasNoise: Bool = false
    var blockTrackers: Bool = true
}

struct BrowserProfile: Identifiable, Codable, Equatable {
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

struct HomeShortcut: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var url: String
    var subtitle: String?
    var color: String?
    var favicon: String?
    var order: Int
}

struct WeatherLocationConfig: Codable, Equatable {
    var name: String = "北京"
    var latitude: Double = 39.9042
    var longitude: Double = 116.4074
    var autoLocate: Bool = true
    var unit: String = "C" // "C" | "F"
}

struct HomeConfig: Codable, Equatable {
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

struct BookmarkItem: Identifiable, Codable, Equatable {
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

struct HistoryItem: Identifiable, Codable, Equatable {
    var id: String
    var url: String
    var title: String
    var profileId: String
    var visitedAt: Double
}

struct PasswordEntry: Identifiable, Codable, Equatable {
    var id: String
    var origin: String
    var username: String
    var password: String
    var note: String?
    var createdAt: Double
    var updatedAt: Double
}

struct SyncScopeToggles: Codable, Equatable {
    var passwords: Bool = true
    var bookmarks: Bool = true
    var home_shortcuts: Bool = true
    var history: Bool = true
    var profiles: Bool = true
    var settings: Bool = true
}

struct PortableSettings: Codable, Equatable {
    var language: AppLang?
    var theme: AppTheme?
    var searchEngine: SearchEngineOption?
    var defaultProxyMode: String?
    var stripTrackingParams: Bool?
    var autoSyncIntervalMinutes: Int?
    var builtInAdblockEnabled: Bool?
    var blockRogueAppJumps: Bool?
    var webDarkModeFollowTheme: Bool?
    var webDarkModeWhitelistHosts: [String]?
}

struct SyncItemPayload: Codable {
    var scope: String
    var itemId: String
    var iv: String
    var ciphertext: String
    var tag: String
    var deleted: Bool
    var updatedAt: Double
}

struct EncryptedEnvelope: Codable {
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
    var kind: String // "tab" | "video" | "clipboard"
    var type: String?
    var targetPlatform: String?
    var title: String?
    var url: String?
    var videoSeconds: Double?
    var text: String?
    var fromDeviceName: String?
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, type, targetPlatform, title, url, videoSeconds, text, fromDeviceName, createdAt
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
