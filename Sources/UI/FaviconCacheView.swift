import CryptoKit
import SwiftUI
import UIKit

@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: Set<String> = []
    private var waiters: [String: [(UIImage?) -> Void]] = [:]
    private let diskCacheDir: URL
    private static let diskCacheTTL: TimeInterval = 7 * 24 * 60 * 60

    private init() {
        cache.countLimit = 300
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Favicons", isDirectory: true)
        self.diskCacheDir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func normalizedHost(from urlString: String) -> String {
        SmartOmniboxEngine.hostOnly(urlString)
    }

    nonisolated private static func diskCacheFileURL(forHost host: String, in dir: URL) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(hex).img")
    }

    func cachedImage(forHost host: String) -> UIImage? {
        let key = host.lowercased() as NSString
        return cache.object(forKey: key)
    }

    func load(host rawHost: String, completion: @escaping (UIImage?) -> Void) {
        let host = rawHost.lowercased()
        guard !host.isEmpty, host.contains(".") else {
            completion(nil)
            return
        }
        if let hit = cachedImage(forHost: host) {
            completion(hit)
            return
        }
        waiters[host, default: []].append(completion)
        guard !inFlight.contains(host) else { return }
        inFlight.insert(host)

        let cacheDir = diskCacheDir
        let ttl = Self.diskCacheTTL
        Task.detached(priority: .utility) {
            let fileURL = Self.diskCacheFileURL(forHost: host, in: cacheDir)
            if let diskData = Self.readFreshDiskCache(at: fileURL, maxAge: ttl),
               let diskImg = Self.decodeValidIcon(from: diskData) {
                await MainActor.run {
                    FaviconLoader.shared.finish(host: host, image: diskImg)
                }
                return
            }

            let fetchedData = await Self.fetchIconWithFallback(host: host)
            let decodedImg = fetchedData.flatMap { Self.decodeValidIcon(from: $0) }
            if let validData = fetchedData, decodedImg != nil {
                try? validData.write(to: fileURL, options: .atomic)
            }
            await MainActor.run {
                FaviconLoader.shared.finish(host: host, image: decodedImg)
            }
        }
    }

    nonisolated private static func readFreshDiskCache(at url: URL, maxAge: TimeInterval) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        if Date().timeIntervalSince(modDate) > maxAge {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url)
    }

    nonisolated private static func decodeValidIcon(from data: Data) -> UIImage? {
        guard let img = UIImage(data: data), img.size.width >= 8, img.size.height >= 8 else {
            return nil
        }
        return img
    }

    nonisolated private static func fetchIconWithFallback(host: String) async -> Data? {
        if let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let s2Url = URL(string: "https://www.google.com/s2/favicons?domain=\(encoded)&sz=64") {
            let s2Req = URLRequest(url: s2Url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.5)
            if let data = await fetchIconData(request: s2Req), decodeValidIcon(from: data) != nil {
                return data
            }
        }
        // Fallback directly to https://<host>/favicon.ico when S2 is blocked or returns placeholder
        if let directUrl = URL(string: "https://\(host)/favicon.ico") {
            let directReq = URLRequest(url: directUrl, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.5)
            if let data = await fetchIconData(request: directReq), decodeValidIcon(from: data) != nil {
                return data
            }
        }
        return nil
    }

    nonisolated private static func fetchIconData(request: URLRequest) async -> Data? {
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    private func finish(host: String, image: UIImage?) {
        inFlight.remove(host)
        if let image {
            cache.setObject(image, forKey: host as NSString)
        }
        let callbacks = waiters.removeValue(forKey: host) ?? []
        for cb in callbacks {
            cb(image)
        }
    }
}

struct FaviconView: View {
    let urlString: String
    let title: String
    var size: CGFloat = 24
    var cornerRadius: CGFloat = 6
    var accentHex: String? = nil

    @State private var loadedImage: UIImage? = nil

    private var host: String {
        FaviconLoader.normalizedHost(from: urlString)
    }

    private var displayImage: UIImage? {
        FaviconLoader.shared.cachedImage(forHost: host) ?? loadedImage
    }

    var body: some View {
        Group {
            if let uiImg = displayImage {
                Image(uiImage: uiImg)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                fallbackBadge
            }
        }
        .onAppear {
            if displayImage == nil {
                FaviconLoader.shared.load(host: host) { img in
                    if let img { loadedImage = img }
                }
            }
        }
        .onChange(of: host) { _, newHost in
            loadedImage = FaviconLoader.shared.cachedImage(forHost: newHost)
            if loadedImage == nil {
                FaviconLoader.shared.load(host: newHost) { img in
                    if let img { loadedImage = img }
                }
            }
        }
    }

    private var fallbackBadge: some View {
        let initial: String = {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ch = cleanTitle.first, ch.isLetter || ch.isNumber {
                return String(ch).uppercased()
            }
            if let ch = host.first, ch.isLetter || ch.isNumber {
                return String(ch).uppercased()
            }
            return "G"
        }()

        let badgeColor: Color = {
            if let accentHex, let c = Color(hex: accentHex) { return c }
            let palette: [Color] = [.blue, .indigo, .purple, .teal, .orange, .pink, .cyan]
            let idx = abs(host.hashValue) % palette.count
            return palette[idx]
        }()

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(badgeColor.gradient)
                .frame(width: size, height: size)
            Text(initial)
                .font(.system(size: max(11, size * 0.48), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
