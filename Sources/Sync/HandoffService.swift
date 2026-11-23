import Foundation
import UIKit

@MainActor
final class HandoffService: ObservableObject {
    @Published var latestIncoming: HandoffPayload?
    @Published var lastPushedAt: Date?
    @Published var isForegroundActive: Bool = true

    private var lastPolledAt: Double = UserDefaults.standard.double(forKey: "prism.handoff.lastPolledAt")
    private var seenIds = Set<String>()
    private var seenIdOrder: [String] = []
    private var pollTimer: Task<Void, Never>?
    private var sseTask: Task<Void, Never>?
    private var sseConnected: Bool = false
    private var sessionObserver: NSObjectProtocol?
    private weak var observedSyncEngine: SyncEngine?
    private var isPolling = false

    func startPolling(syncEngine: SyncEngine) {
        handleForegroundResume(syncEngine: syncEngine)
    }

    func setForeground(_ active: Bool, syncEngine: SyncEngine) {
        if active {
            handleForegroundResume(syncEngine: syncEngine)
        } else {
            pauseForBackground()
        }
    }

    func handleForegroundResume(syncEngine: SyncEngine) {
        isForegroundActive = true
        observedSyncEngine = syncEngine
        ensureSessionObserver()
        startSseIfNeeded(syncEngine: syncEngine)

        pollTimer?.cancel()
        pollTimer = Task { [weak self, weak syncEngine] in
            // Trigger immediate foreground catch-up poll
            try? await Task.sleep(nanoseconds: 50_000_000)
            while !Task.isCancelled {
                guard let self, let syncEngine, self.isForegroundActive else { break }
                if syncEngine.loggedIn, syncEngine.unlocked {
                    await self.pollOnce(syncEngine: syncEngine)
                }
                let sleepNs: UInt64 = self.sseConnected ? 120_000_000_000 : 15_000_000_000
                try? await Task.sleep(nanoseconds: sleepNs)
            }
        }
    }

    func pauseForBackground() {
        isForegroundActive = false
        pollTimer?.cancel()
        pollTimer = nil
        sseTask?.cancel()
        sseTask = nil
        sseConnected = false
    }

    private func ensureSessionObserver() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: .prismSyncSessionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let syncEngine = self.observedSyncEngine else { return }
                self.startSseIfNeeded(syncEngine: syncEngine)
            }
        }
    }

    private func startSseIfNeeded(syncEngine: SyncEngine) {
        guard isForegroundActive, syncEngine.loggedIn, syncEngine.unlocked else {
            sseTask?.cancel()
            sseTask = nil
            sseConnected = false
            return
        }
        if sseTask != nil { return }
        sseTask = Task { [weak self, weak syncEngine] in
            var backoffSeconds: UInt64 = 2
            var hadConnectedOnce = false
            while !Task.isCancelled {
                guard let self, let syncEngine, self.isForegroundActive,
                      syncEngine.loggedIn, syncEngine.unlocked,
                      let token = syncEngine.currentToken,
                      let url = URL(string: "\(syncEngine.serverUrl)/api/events?platform=ios") else {
                    break
                }
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                req.timeoutInterval = 3600

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    if http.statusCode == 401 {
                        syncEngine.logout()
                        break
                    }
                    guard http.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }

                    backoffSeconds = 2
                    let wasReconnect = hadConnectedOnce
                    hadConnectedOnce = true
                    self.sseConnected = true

                    // Catch up immediately on connect / reconnect so no handoffs or sync updates are missed
                    await self.pollOnce(syncEngine: syncEngine)
                    if wasReconnect {
                        await syncEngine.syncNow(forceFullPull: false)
                    }

                    var lineBuffer = Data()
                    var currentEvent = "message"
                    var dataBuffer = ""

                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A { // '\n' — iterate raw bytes so Darwin AsyncLineSequence never swallows blank \n\n delimiters
                            let rawLine = String(data: lineBuffer, encoding: .utf8) ?? ""
                            lineBuffer.removeAll(keepingCapacity: true)
                            let clean = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                            if clean.isEmpty {
                                if currentEvent == "wakeup", !dataBuffer.isEmpty {
                                    await self.handleSseWakeup(dataBuffer, syncEngine: syncEngine)
                                }
                                currentEvent = "message"
                                dataBuffer = ""
                            } else if clean.hasPrefix(":") {
                                continue
                            } else if clean.hasPrefix("event:") {
                                currentEvent = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            } else if clean.hasPrefix("data:") {
                                let part = String(clean.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                                dataBuffer = dataBuffer.isEmpty ? part : (dataBuffer + "\n" + part)
                            }
                        } else {
                            lineBuffer.append(byte)
                        }
                    }
                } catch {
                    // Transient network drop; reconnect with exponential backoff below
                }

                self.sseConnected = false
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(20, backoffSeconds * 2)
            }
            if let self {
                self.sseConnected = false
                self.sseTask = nil
            }
        }
    }

    private func handleSseWakeup(_ rawJson: String, syncEngine: SyncEngine) async {
        struct WakeupPayload: Decodable {
            let reason: String?
        }
        if let data = rawJson.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(WakeupPayload.self, from: data) {
            if decoded.reason == "sync" {
                await syncEngine.syncNow(forceFullPull: false)
                return
            }
        }
        await pollOnce(syncEngine: syncEngine)
    }

    struct PreparedHandoffImage: Sendable {
        let dataUrl: String
        let width: Int
        let height: Int
        let filename: String
    }

    nonisolated static func prepareImagePayload(rawData: Data?, image: UIImage?, preferredFilename: String? = nil) -> PreparedHandoffImage? {
        let maxLosslessBytes = 550 * 1024
        let maxCompressedBytes = 600 * 1024

        let baseImage: UIImage? = image ?? rawData.flatMap { UIImage(data: $0) }
        let pixelW = baseImage.map { Int(($0.size.width * $0.scale).rounded()) } ?? 0
        let pixelH = baseImage.map { Int(($0.size.height * $0.scale).rounded()) } ?? 0

        if let rawData, !rawData.isEmpty, rawData.count <= maxLosslessBytes {
            if let detected = detectMimeAndExt(for: rawData) {
                let fallbackName = "prism-image-\(Int(Date().timeIntervalSince1970)).\(detected.ext)"
                let cleanName = (preferredFilename?.isEmpty == false ? preferredFilename! : fallbackName)
                let b64 = rawData.base64EncodedString()
                return PreparedHandoffImage(
                    dataUrl: "data:\(detected.mime);base64,\(b64)",
                    width: pixelW,
                    height: pixelH,
                    filename: cleanName
                )
            }
        }

        guard let sourceImage = baseImage else { return nil }

        // Ensure orientation-normalized UIImage before encoding
        let longEdges: [CGFloat] = [1920, 1440, 1080, 800]
        let qualities: [CGFloat] = [0.82, 0.70, 0.56]

        for maxEdge in longEdges {
            let scaled = downscaleIfNeeded(sourceImage, maxLongEdge: maxEdge)
            let w = Int((scaled.size.width * scaled.scale).rounded())
            let h = Int((scaled.size.height * scaled.scale).rounded())
            for q in qualities {
                if let jpeg = scaled.jpegData(compressionQuality: q), jpeg.count <= maxCompressedBytes {
                    let baseStem = ((preferredFilename as NSString?)?.deletingPathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "prism-image-\(Int(Date().timeIntervalSince1970))"
                    let cleanName = "\(baseStem).jpg"
                    return PreparedHandoffImage(
                        dataUrl: "data:image/jpeg;base64,\(jpeg.base64EncodedString())",
                        width: w,
                        height: h,
                        filename: cleanName
                    )
                }
            }
        }
        return nil
    }

    nonisolated private static func detectMimeAndExt(for data: Data) -> (mime: String, ext: String)? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return ("image/png", "png")
        }
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return ("image/jpeg", "jpg")
        }
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
            bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return ("image/webp", "webp")
        }
        return nil
    }

    nonisolated private static func downscaleIfNeeded(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > 0 else { return image }
        let targetSize: CGSize = longEdge > maxLongEdge
            ? CGSize(width: floor(size.width * (maxLongEdge / longEdge)), height: floor(size.height * (maxLongEdge / longEdge)))
            : size
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: fmt)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    nonisolated static func decodeImage(fromDataUrl dataUrl: String) -> UIImage? {
        guard let commaIdx = dataUrl.firstIndex(of: ",") else { return nil }
        let b64 = String(dataUrl[dataUrl.index(after: commaIdx)...])
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }

    func pushImage(rawData: Data? = nil, image: UIImage? = nil, filename: String? = nil, title: String? = nil, syncEngine: SyncEngine) async -> Bool {
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepareImagePayload(rawData: rawData, image: image, preferredFilename: filename)
        }.value
        guard let prepared else { return false }
        return await push(
            kind: "image",
            title: title ?? prepared.filename,
            url: nil,
            videoSeconds: nil,
            text: nil,
            imageDataUrl: prepared.dataUrl,
            imageWidth: prepared.width > 0 ? prepared.width : nil,
            imageHeight: prepared.height > 0 ? prepared.height : nil,
            filename: prepared.filename,
            syncEngine: syncEngine
        )
    }

    func push(
        kind: String,
        title: String?,
        url: String?,
        videoSeconds: Double? = nil,
        text: String? = nil,
        imageDataUrl: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        filename: String? = nil,
        syncEngine: SyncEngine
    ) async -> Bool {
        guard let token = syncEngine.currentToken,
              let encKey = syncEngine.currentEncKey,
              let endpoint = URL(string: "\(syncEngine.serverUrl)/api/handoff/push") else {
            return false
        }
        let payloadId = UUID().uuidString
        let outerKind = (kind == "image") ? "clipboard" : kind
        let payload = HandoffPayload(
            id: payloadId,
            kind: kind,
            type: kind,
            targetPlatform: "desktop",
            title: title,
            url: url,
            videoSeconds: videoSeconds,
            text: text,
            imageDataUrl: imageDataUrl,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            filename: filename,
            fromDeviceName: syncEngine.deviceName,
            createdAt: Date().timeIntervalSince1970 * 1000
        )
        guard let envelope = try? CryptoVault.encryptJSON(payload, encKey: encKey) else { return false }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = (kind == "image") ? 25.0 : 15.0
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": payloadId,
            "kind": outerKind,
            "type": outerKind,
            "targetPlatform": "desktop",
            "iv": envelope.iv,
            "ciphertext": envelope.ciphertext,
            "tag": envelope.tag,
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                lastPushedAt = Date()
                return true
            }
        } catch {
            return false
        }
        return false
    }

    private func markSeenId(_ id: String) {
        guard seenIds.insert(id).inserted else { return }
        seenIdOrder.append(id)
        if seenIds.count > 500, seenIdOrder.count > 400 {
            let removeCount = seenIdOrder.count - 400
            for oldId in seenIdOrder.prefix(removeCount) {
                seenIds.remove(oldId)
            }
            seenIdOrder.removeFirst(removeCount)
        }
    }

    func pollOnce(syncEngine: SyncEngine) async {
        guard !isPolling else { return }
        guard let token = syncEngine.currentToken,
              let encKey = syncEngine.currentEncKey,
              let url = URL(string: "\(syncEngine.serverUrl)/api/handoff/poll?since=\(Int(lastPolledAt))&platform=ios") else {
            return
        }
        isPolling = true
        defer { isPolling = false }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                syncEngine.logout()
                return
            }
            guard http.statusCode == 200 else { return }
            struct PollItem: Decodable {
                let id: String
                let fromDeviceId: String
                let fromDeviceName: String?
                let kind: String?
                let type: String?
                let iv: String
                let ciphertext: String
                let tag: String
                let createdAt: Double
            }
            struct PollResp: Decodable {
                let ok: Bool
                let serverTime: Double?
                let currentDeviceId: String?
                let items: [PollItem]
            }
            let decoded = try JSONDecoder().decode(PollResp.self, from: data)
            var newestIncoming: HandoffPayload?
            for item in decoded.items {
                if item.fromDeviceId == decoded.currentDeviceId || seenIds.contains(item.id) { continue }
                markSeenId(item.id)
                if var payload = try? CryptoVault.decryptJSON(HandoffPayload.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    payload.id = item.id
                    if let imgData = payload.imageDataUrl, !imgData.isEmpty {
                        payload.kind = "image"
                    } else if payload.kind.isEmpty {
                        payload.kind = item.kind ?? item.type ?? "tab"
                    }
                    payload.fromDeviceName = item.fromDeviceName ?? payload.fromDeviceName
                    if item.createdAt > 0 {
                        payload.createdAt = item.createdAt
                    }
                    if newestIncoming == nil || payload.createdAt >= newestIncoming!.createdAt {
                        newestIncoming = payload
                    }
                }
            }
            if let newestIncoming {
                latestIncoming = newestIncoming
            }
            if let serverTime = decoded.serverTime {
                lastPolledAt = max(lastPolledAt, serverTime)
                UserDefaults.standard.set(lastPolledAt, forKey: "prism.handoff.lastPolledAt")
            }
        } catch {
            // Silent retry next cycle
        }
    }
}
