import SwiftUI
import UIKit

@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: Set<String> = []
    private var waiters: [String: [(UIImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 300
    }

    static func normalizedHost(from urlString: String) -> String {
        SmartOmniboxEngine.hostOnly(urlString)
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

        guard let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/s2/favicons?domain=\(encoded)&sz=64") else {
            finish(host: host, image: nil)
            return
        }

        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6.0)
        Task.detached(priority: .utility) {
            let data: Data? = await Self.fetchIconData(request: request)
            await MainActor.run {
                let img: UIImage? = data.flatMap { UIImage(data: $0) }.flatMap { $0.size.width >= 8 ? $0 : nil }
                FaviconLoader.shared.finish(host: host, image: img)
            }
        }
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
