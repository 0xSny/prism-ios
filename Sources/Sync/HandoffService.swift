import Foundation

@MainActor
final class HandoffService: ObservableObject {
    @Published var latestIncoming: HandoffPayload?
    @Published var lastPushedAt: Date?
    @Published var isForegroundActive: Bool = true

    private var lastPolledAt: Double = UserDefaults.standard.double(forKey: "prism.handoff.lastPolledAt")
    private var seenIds = Set<String>()
    private var pollTimer: Task<Void, Never>?
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
        pollTimer?.cancel()
        pollTimer = Task { [weak self, weak syncEngine] in
            // Trigger immediate foreground poll within 0.1s
            try? await Task.sleep(nanoseconds: 50_000_000)
            while !Task.isCancelled {
                guard let self, let syncEngine, self.isForegroundActive else { break }
                if syncEngine.loggedIn, syncEngine.unlocked {
                    await self.pollOnce(syncEngine: syncEngine)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func pauseForBackground() {
        isForegroundActive = false
        pollTimer?.cancel()
        pollTimer = nil
    }

    func push(kind: String, title: String?, url: String?, videoSeconds: Double? = nil, text: String? = nil, syncEngine: SyncEngine) async -> Bool {
        guard let token = syncEngine.currentToken,
              let encKey = syncEngine.currentEncKey,
              let endpoint = URL(string: "\(syncEngine.serverUrl)/api/handoff/push") else {
            return false
        }
        let payloadId = UUID().uuidString
        let payload = HandoffPayload(
            id: payloadId,
            kind: kind,
            type: kind,
            targetPlatform: "desktop",
            title: title,
            url: url,
            videoSeconds: videoSeconds,
            text: text,
            fromDeviceName: syncEngine.deviceName,
            createdAt: Date().timeIntervalSince1970 * 1000
        )
        guard let envelope = try? CryptoVault.encryptJSON(payload, encKey: encKey) else { return false }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": payloadId,
            "kind": kind,
            "type": kind,
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
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
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
            for item in decoded.items {
                if item.fromDeviceId == decoded.currentDeviceId || seenIds.contains(item.id) { continue }
                seenIds.insert(item.id)
                if var payload = try? CryptoVault.decryptJSON(HandoffPayload.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    payload.id = item.id
                    if payload.kind.isEmpty {
                        payload.kind = item.kind ?? item.type ?? "tab"
                    }
                    payload.fromDeviceName = item.fromDeviceName ?? payload.fromDeviceName
                    if item.createdAt > 0 {
                        payload.createdAt = item.createdAt
                    }
                    latestIncoming = payload
                    break
                }
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
