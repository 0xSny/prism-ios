import Foundation

@MainActor
final class HandoffService: ObservableObject {
    @Published var latestIncoming: HandoffPayload?
    @Published var lastPushedAt: Date?

    private var lastPolledAt: Double = UserDefaults.standard.double(forKey: "prism.handoff.lastPolledAt")
    private var seenIds = Set<String>()
    private var pollTimer: Task<Void, Never>?

    func startPolling(syncEngine: SyncEngine) {
        pollTimer?.cancel()
        pollTimer = Task { [weak self, weak syncEngine] in
            while !Task.isCancelled {
                if let self, let syncEngine, syncEngine.loggedIn, syncEngine.unlocked {
                    await self.pollOnce(syncEngine: syncEngine)
                }
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }

    func push(kind: String, title: String?, url: String?, videoSeconds: Double? = nil, text: String? = nil, syncEngine: SyncEngine) async -> Bool {
        guard let token = syncEngine.currentToken,
              let encKey = syncEngine.currentEncKey,
              let endpoint = URL(string: "\(syncEngine.serverUrl)/api/handoff/push") else {
            return false
        }
        let payload = HandoffPayload(
            id: UUID().uuidString,
            kind: kind,
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
            "kind": kind,
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
        guard let token = syncEngine.currentToken,
              let encKey = syncEngine.currentEncKey,
              let url = URL(string: "\(syncEngine.serverUrl)/api/handoff/poll?since=\(Int(lastPolledAt))") else {
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            struct PollItem: Decodable {
                let id: String
                let fromDeviceId: String
                let fromDeviceName: String?
                let kind: String
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
                    payload.fromDeviceName = item.fromDeviceName ?? payload.fromDeviceName
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
