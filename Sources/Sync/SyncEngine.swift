import CryptoKit
import Foundation
import UIKit

extension Notification.Name {
    static let prismSyncSessionChanged = Notification.Name("PrismSyncSessionChanged")
}

struct SyncTombstone: Codable, Equatable, Sendable {
    var scope: String
    var itemId: String
    var updatedAt: Double
}

private actor LocalCacheWriter {
    func write<T: Encodable & Sendable>(_ snapshot: T, to url: URL) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private struct SyncDiskSnapshot: Codable, Sendable {
    var bookmarks: [BookmarkItem]
    var passwords: [PasswordEntry]
    var history: [HistoryItem]
    var homeConfig: HomeConfig
    var profiles: [BrowserProfile]
    var pendingTombstones: [SyncTombstone]?
    var lastPushedHashes: [String: String]?
}

private struct DecryptedPullBatch: Sendable {
    var deletedBookmarkIds: [String] = []
    var upsertedBookmarks: [BookmarkItem] = []
    var deletedPasswordRawIds: [String] = []
    var upsertedPasswords: [PasswordEntry] = []
    var remoteHomeConfig: HomeConfig? = nil
    var deletedProfileRawIds: [String] = []
    var upsertedProfiles: [BrowserProfile] = []
    var deletedHistoryItems: [(itemId: String, updatedAt: Double)] = []
    var upsertedHistory: [HistoryItem] = []
    var remotePortableSettings: PortableSettings? = nil
    var syncedHashes: [String: String] = [:]
}

private struct OutboundSyncBuildResult: Sendable {
    var items: [SyncItemPayload]
    var encodedBody: Data?
    var updatedHashes: [String: String]
    var deletedKeys: Set<String>
}

@MainActor
final class SyncEngine: ObservableObject {
    static let defaultServerUrl = "https://prism.zzaoo.com"

    @Published var loggedIn: Bool = false
    @Published var unlocked: Bool = false
    @Published var email: String = ""
    @Published var userId: String = ""
    @Published var deviceId: String = ""
    @Published var deviceName: String = UIDevice.current.name
    @Published var serverUrl: String = defaultServerUrl
    @Published var lastSyncedAt: Double? = nil
    @Published var syncing: Bool = false
    @Published var lastError: String? = nil
    @Published var autoSyncIntervalMinutes: Int = 5

    @Published var passwords: [PasswordEntry] = []
    @Published var bookmarks: [BookmarkItem] = []
    @Published var history: [HistoryItem] = []
    @Published var homeConfig: HomeConfig = HomeConfig()
    @Published var profiles: [BrowserProfile] = [.defaultProfile]
    @Published var scopes: SyncScopeToggles = SyncScopeToggles()

    private var token: String?
    private var kdfSalt: String?
    private var encKey: Data?
    private var lastPulledAt: Double = 0
    private var dirtyScopes = Set<String>()
    private var dirtyBookmarkIds = Set<String>()
    private var dirtyPasswordIds = Set<String>()
    private var pendingTombstones: [SyncTombstone] = []
    private var lastPushedHashes: [String: String] = [:]
    private var debounceTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?

    private let cacheDir: URL
    private let cacheWriter = LocalCacheWriter()
    var onRemotePortableSettings: ((PortableSettings) -> Void)?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.cacheDir = base.appendingPathComponent("prism-sync-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        self.autoSyncIntervalMinutes = UserDefaults.standard.object(forKey: "prism.autoSyncInterval") as? Int ?? 5
        loadLocalCache()

        if let saved = CryptoVault.loadSession() {
            self.loggedIn = true
            self.email = saved.email
            self.userId = saved.userId
            self.deviceId = saved.deviceId
            self.deviceName = saved.deviceName.isEmpty ? UIDevice.current.name : saved.deviceName
            self.serverUrl = saved.serverUrl.isEmpty ? Self.defaultServerUrl : saved.serverUrl
            self.lastSyncedAt = saved.lastSyncedAt
            self.lastPulledAt = saved.lastPulledAt ?? 0
            self.token = saved.token
            self.kdfSalt = saved.kdfSalt
            if let keyB64 = saved.encKeyB64, let keyData = Data(base64Encoded: keyB64), keyData.count == 32 {
                self.encKey = keyData
                self.unlocked = true
            }
            Task { [weak self] in
                await self?.verifySession()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await self?.syncNow(forceFullPull: false)
            }
        }
        rescheduleAutoSync()
    }

    var currentEncKey: Data? { encKey }
    var currentToken: String? { token }

    func updateAutoSyncInterval(_ minutes: Int) {
        let clamped = minutes <= 0 ? 0 : min(720, max(1, minutes))
        autoSyncIntervalMinutes = clamped
        UserDefaults.standard.set(clamped, forKey: "prism.autoSyncInterval")
        rescheduleAutoSync()
        notifyScopeDirty("settings")
    }

    private func rescheduleAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        guard autoSyncIntervalMinutes > 0 else { return }
        let intervalNs = UInt64(autoSyncIntervalMinutes) * 60 * 1_000_000_000
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard let self, !Task.isCancelled else { break }
                if self.loggedIn && self.unlocked {
                    await self.syncNow(forceFullPull: false)
                }
            }
        }
    }

    func notifyScopeDirty(_ scope: String) {
        dirtyScopes.insert(scope)
        saveLocalCache()
        guard loggedIn && unlocked else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.syncNow(forceFullPull: false)
        }
    }

    func flushPendingBeforeBackground() async {
        guard loggedIn && unlocked && !dirtyScopes.isEmpty else { return }
        debounceTask?.cancel()
        await syncNow(forceFullPull: false)
    }

    // MARK: - Auth Flows

    func sendVerificationCode(email rawEmail: String) async -> (Bool, String?) {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lang = L10n.isEnglish ? "en" : "zh"
        guard let url = URL(string: "\(serverUrl)/api/auth/send-code") else { return (false, "Invalid URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "purpose": "register",
            "lang": lang,
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if let http = resp as? HTTPURLResponse, http.statusCode >= 200 && http.statusCode < 300,
               (json["ok"] as? Bool) == true {
                return (true, nil)
            }
            return (false, (json["message"] as? String) ?? (json["error"] as? String) ?? L10n.t("验证码发送失败", "Failed to send code"))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func register(email rawEmail: String, password: String, code: String) async -> Bool {
        lastError = nil
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let salt = CryptoVault.generateSaltBase64Url()
        do {
            let derived = try await Task.detached(priority: .userInitiated) {
                try CryptoVault.deriveKeys(masterPassword: password, kdfSalt: salt)
            }.value

            guard let url = URL(string: "\(serverUrl)/api/auth/register") else { return false }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "email": email,
                "verificationCode": code.trimmingCharacters(in: .whitespacesAndNewlines),
                "kdfSalt": salt,
                "authKey": derived.authKey,
                "deviceName": UIDevice.current.name,
                "platform": "ios",
                "appVersion": "1.1.4",
            ])

            let (data, resp) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard let http = resp as? HTTPURLResponse, http.statusCode >= 200 && http.statusCode < 300,
                  let token = json["token"] as? String,
                  let user = json["user"] as? [String: Any] else {
                lastError = (json["error"] as? String) ?? (json["message"] as? String) ?? L10n.t("注册失败", "Registration failed")
                return false
            }

            let device = json["device"] as? [String: Any]
            let devId = (device?["id"] as? String) ?? UUID().uuidString
            let uid = (user["id"] as? String) ?? ""
            let session = AccountSessionDisk(
                serverUrl: serverUrl,
                token: token,
                email: email,
                userId: uid,
                kdfSalt: salt,
                deviceId: devId,
                deviceName: UIDevice.current.name,
                lastSyncedAt: nil,
                lastPulledAt: 0,
                encKeyB64: derived.encKey.base64EncodedString()
            )
            applyAuthenticatedSession(session, encKey: derived.encKey)
            await syncNow(forceFullPull: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func login(email rawEmail: String, password: String) async -> Bool {
        lastError = nil
        let cleanEmail = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let encodedEmail = cleanEmail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let paramsUrl = URL(string: "\(serverUrl)/api/auth/params?email=\(encodedEmail)") else {
            return false
        }
        do {
            let (pData, pResp) = try await URLSession.shared.data(from: paramsUrl)
            let pJson = (try? JSONSerialization.jsonObject(with: pData) as? [String: Any]) ?? [:]
            guard let pHttp = pResp as? HTTPURLResponse, pHttp.statusCode == 200,
                  let kdfSalt = pJson["kdfSalt"] as? String else {
                lastError = (pJson["error"] as? String) ?? L10n.t("账号不存在", "Account not found")
                return false
            }

            let derived = try await Task.detached(priority: .userInitiated) {
                try CryptoVault.deriveKeys(masterPassword: password, kdfSalt: kdfSalt)
            }.value

            guard let loginUrl = URL(string: "\(serverUrl)/api/auth/login") else { return false }
            var req = URLRequest(url: loginUrl)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "email": cleanEmail,
                "authKey": derived.authKey,
                "deviceName": UIDevice.current.name,
                "platform": "ios",
                "appVersion": "1.1.4",
            ])

            let (data, resp) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let token = json["token"] as? String,
                  let user = json["user"] as? [String: Any] else {
                lastError = (json["error"] as? String) ?? L10n.t("邮箱或主密码错误", "Invalid email or master password")
                return false
            }

            let device = json["device"] as? [String: Any]
            let devId = (device?["id"] as? String) ?? UUID().uuidString
            let uid = (user["id"] as? String) ?? ""
            let session = AccountSessionDisk(
                serverUrl: serverUrl,
                token: token,
                email: cleanEmail,
                userId: uid,
                kdfSalt: kdfSalt,
                deviceId: devId,
                deviceName: UIDevice.current.name,
                lastSyncedAt: nil,
                lastPulledAt: 0,
                encKeyB64: derived.encKey.base64EncodedString()
            )
            applyAuthenticatedSession(session, encKey: derived.encKey)
            await syncNow(forceFullPull: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func logout() {
        debounceTask?.cancel()
        if let token, let url = URL(string: "\(serverUrl)/api/auth/logout") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req).resume()
        }
        CryptoVault.clearSession()
        loggedIn = false
        unlocked = false
        email = ""
        userId = ""
        deviceId = ""
        lastSyncedAt = nil
        lastPulledAt = 0
        token = nil
        kdfSalt = nil
        encKey = nil
        lastPushedHashes.removeAll()
        NotificationCenter.default.post(name: .prismSyncSessionChanged, object: nil)
    }

    func sendResetCode(email rawEmail: String) async -> (Bool, String?) {
        let cleanEmail = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lang = L10n.isEnglish ? "en" : "zh"
        guard let url = URL(string: "\(serverUrl)/api/auth/send-code") else { return (false, "Invalid URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": cleanEmail,
            "purpose": "reset",
            "lang": lang,
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if let http = resp as? HTTPURLResponse, http.statusCode >= 200 && http.statusCode < 300,
               (json["ok"] as? Bool) == true {
                return (true, nil)
            }
            return (false, (json["message"] as? String) ?? (json["error"] as? String) ?? L10n.t("发送重置验证码失败", "Failed to send reset code"))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func generateRecoveryKey() async -> (Bool, String?) {
        guard loggedIn, unlocked, let token, let encKey,
              let url = URL(string: "\(serverUrl)/api/auth/recovery-backup") else {
            return (false, L10n.t("需先登录并解锁", "Sign in first"))
        }
        let formattedKey = CryptoVault.generateRecoveryKey24()
        let wrapKey = CryptoVault.deriveRecoveryWrapKey(recoveryKey: formattedKey, email: email)
        struct EncWrap: Encodable {
            let encKeyB64: String
            let v: Int
        }
        guard let blob = try? CryptoVault.encryptJSON(EncWrap(encKeyB64: encKey.base64EncodedString(), v: 1), encKey: wrapKey) else {
            return (false, "Encrypt recovery blob failed")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "recoveryBlob": [
                "iv": blob.iv,
                "ciphertext": blob.ciphertext,
                "tag": blob.tag,
            ]
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return (true, formattedKey)
            }
            return (false, "HTTP error")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func resetPassword(email rawEmail: String, code: String, newPassword: String, recoveryKey: String) async -> Bool {
        lastError = nil
        let cleanEmail = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSalt = CryptoVault.generateSaltBase64Url()
        do {
            let newDerived = try await Task.detached(priority: .userInitiated) {
                try CryptoVault.deriveKeys(masterPassword: newPassword, kdfSalt: newSalt)
            }.value

            var bodyDict: [String: Any] = [
                "email": cleanEmail,
                "verificationCode": cleanCode,
                "newKdfSalt": newSalt,
                "newAuthKey": newDerived.authKey,
                "wipeOldCiphertext": true,
                "deviceName": UIDevice.current.name,
                "platform": "ios",
                "appVersion": "1.1.4",
            ]

            let cleanRec = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanRec.isEmpty {
                guard let normalizedRec = CryptoVault.normalizeRecoveryKey(cleanRec) else {
                    lastError = L10n.t("恢复密钥格式无效（需 24 位字符），已中止重置以保护云端数据", "Invalid 24-character recovery key; reset aborted to protect cloud data")
                    return false
                }
                guard let prepUrl = URL(string: "\(serverUrl)/api/auth/reset-prepare") else {
                    lastError = L10n.t("服务器地址无效", "Invalid server URL")
                    return false
                }
                var prepReq = URLRequest(url: prepUrl)
                prepReq.httpMethod = "POST"
                prepReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                prepReq.httpBody = try JSONSerialization.data(withJSONObject: [
                    "email": cleanEmail,
                    "verificationCode": cleanCode,
                ])
                let (pData, pResp) = try await URLSession.shared.data(for: prepReq)
                struct PrepItem: Decodable {
                    let scope: String
                    let itemId: String
                    let iv: String
                    let ciphertext: String
                    let tag: String
                    let deleted: Bool
                    let updatedAt: Double
                }
                struct PrepResp: Decodable {
                    let ok: Bool
                    let error: String?
                    let recoveryBlob: EncryptedEnvelope?
                    let items: [PrepItem]?
                }
                guard let pHttp = pResp as? HTTPURLResponse,
                      let prep = try? JSONDecoder().decode(PrepResp.self, from: pData) else {
                    lastError = L10n.t("拉取云端恢复凭据失败，请稍后重试", "Failed to fetch cloud recovery credentials")
                    return false
                }
                guard pHttp.statusCode == 200, prep.ok, let blob = prep.recoveryBlob else {
                    lastError = prep.error ?? L10n.t("未找到云端恢复凭据或验证码错误，已中止重置", "Missing recovery blob or invalid code; reset aborted")
                    return false
                }
                struct DecWrap: Decodable { let encKeyB64: String }
                struct EncWrap: Encodable { let encKeyB64: String; let v: Int }
                let wrapKey = CryptoVault.deriveRecoveryWrapKey(recoveryKey: normalizedRec, email: cleanEmail)
                let dec: DecWrap
                do {
                    dec = try CryptoVault.decryptJSON(DecWrap.self, encKey: wrapKey, ivB64: blob.iv, ciphertextB64: blob.ciphertext, tagB64: blob.tag)
                } catch {
                    lastError = L10n.t("恢复密钥校验失败，无法解密云端密钥", "Recovery key mismatch; unable to unwrap cloud key")
                    return false
                }
                guard let oldKey = Data(base64Encoded: dec.encKeyB64), oldKey.count == 32 else {
                    lastError = L10n.t("云端恢复密钥载荷异常，已中止重置", "Corrupt recovery key payload; reset aborted")
                    return false
                }
                // Migrate encrypted sync items locally cleanly via AES-256-GCM
                var migrated: [[String: Any]] = []
                let nKey = SymmetricKey(data: newDerived.encKey)
                let oKey = SymmetricKey(data: oldKey)
                for it in (prep.items ?? []) {
                    if let ivD = Data(base64Encoded: it.iv), let ctD = Data(base64Encoded: it.ciphertext), let tagD = Data(base64Encoded: it.tag),
                       let nonce = try? AES.GCM.Nonce(data: ivD),
                       let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ctD, tag: tagD),
                       let plain = try? AES.GCM.open(box, using: oKey),
                       let resealed = try? AES.GCM.seal(plain, using: nKey) {
                        migrated.append([
                            "scope": it.scope,
                            "itemId": it.itemId,
                            "iv": resealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
                            "ciphertext": resealed.ciphertext.base64EncodedString(),
                            "tag": resealed.tag.base64EncodedString(),
                            "deleted": it.deleted,
                            "updatedAt": it.updatedAt,
                        ])
                    }
                }
                if let newBlob = try? CryptoVault.encryptJSON(EncWrap(encKeyB64: newDerived.encKey.base64EncodedString(), v: 1), encKey: wrapKey) {
                    bodyDict["newRecoveryBlob"] = ["iv": newBlob.iv, "ciphertext": newBlob.ciphertext, "tag": newBlob.tag]
                }
                bodyDict["migratedItems"] = migrated
                bodyDict["wipeOldCiphertext"] = false
            }

            guard let resetUrl = URL(string: "\(serverUrl)/api/auth/reset-password") else { return false }
            var req = URLRequest(url: resetUrl)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

            let (data, resp) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let token = json["token"] as? String,
                  let user = json["user"] as? [String: Any] else {
                lastError = (json["error"] as? String) ?? L10n.t("重置失败", "Reset failed")
                return false
            }

            let device = json["device"] as? [String: Any]
            let devId = (device?["id"] as? String) ?? UUID().uuidString
            let uid = (user["id"] as? String) ?? ""
            let session = AccountSessionDisk(
                serverUrl: serverUrl,
                token: token,
                email: cleanEmail,
                userId: uid,
                kdfSalt: newSalt,
                deviceId: devId,
                deviceName: UIDevice.current.name,
                lastSyncedAt: nil,
                lastPulledAt: 0,
                encKeyB64: newDerived.encKey.base64EncodedString()
            )
            applyAuthenticatedSession(session, encKey: newDerived.encKey)
            dirtyScopes.formUnion(["passwords", "bookmarks", "home_shortcuts", "profiles", "settings"])
            await syncNow(forceFullPull: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func verifySession() async {
        guard let token, let url = URL(string: "\(serverUrl)/api/auth/session") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            logout()
        }
    }

    private func applyAuthenticatedSession(_ session: AccountSessionDisk, encKey: Data) {
        if self.userId != session.userId {
            self.lastPushedHashes.removeAll()
        }
        self.token = session.token
        self.email = session.email
        self.userId = session.userId
        self.kdfSalt = session.kdfSalt
        self.deviceId = session.deviceId
        self.encKey = encKey
        self.loggedIn = true
        self.unlocked = true
        self.lastPulledAt = session.lastPulledAt ?? 0
        CryptoVault.saveSession(session)
        NotificationCenter.default.post(name: .prismSyncSessionChanged, object: nil)
    }

    // MARK: - Encrypted Bidirectional Sync

    func syncNow(forceFullPull: Bool) async {
        guard loggedIn, unlocked, let token, let encKey, !syncing else { return }
        syncing = true
        lastError = nil
        defer { syncing = false }

        let since = forceFullPull ? 0 : Int(lastPulledAt)
        guard let pullUrl = URL(string: "\(serverUrl)/api/sync/pull?since=\(since)") else { return }
        var pullReq = URLRequest(url: pullUrl)
        pullReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (pullData, pullResp) = try await URLSession.shared.data(for: pullReq)
            guard let pullHttp = pullResp as? HTTPURLResponse, pullHttp.statusCode == 200 else {
                lastError = "Pull HTTP error"
                return
            }
            struct PullResponse: Decodable {
                let ok: Bool
                let serverTime: Double?
                let items: [SyncItemPayload]
            }
            let decoded = try JSONDecoder().decode(PullResponse.self, from: pullData)
            let pullScopes = self.scopes
            let pullTombstones = self.pendingTombstones
            let pullItems = decoded.items
            let pullBatch = await Task.detached(priority: .utility) {
                Self.decryptPulledItems(
                    pullItems,
                    encKey: encKey,
                    scopes: pullScopes,
                    pendingTombstones: pullTombstones
                )
            }.value
            applyDecryptedPullBatch(pullBatch)

            let processedDirtyScopes = dirtyScopes
            let processedDirtyBookmarkIds = dirtyBookmarkIds
            let processedDirtyPasswordIds = dirtyPasswordIds
            let snapScopes = self.scopes
            let snapBookmarks = self.bookmarks
            let snapPasswords = self.passwords
            let snapHistory = self.history
            let snapProfiles = self.profiles
            let snapHomeConfig = self.homeConfig
            let snapTombstones = self.pendingTombstones
            let snapHashes = self.lastPushedHashes
            let snapPortable = buildCurrentPortableSettings()

            let outbound = await Task.detached(priority: .utility) {
                Self.buildOutboundPayload(
                    encKey: encKey,
                    targetScopes: processedDirtyScopes,
                    targetBookmarkIds: processedDirtyBookmarkIds,
                    targetPasswordIds: processedDirtyPasswordIds,
                    scopes: snapScopes,
                    bookmarks: snapBookmarks,
                    passwords: snapPasswords,
                    history: snapHistory,
                    profiles: snapProfiles,
                    homeConfig: snapHomeConfig,
                    pendingTombstones: snapTombstones,
                    portableSettings: snapPortable,
                    lastPushedHashes: snapHashes
                )
            }.value

            if outbound.items.isEmpty {
                dirtyScopes.subtract(processedDirtyScopes)
                dirtyBookmarkIds.subtract(processedDirtyBookmarkIds)
                dirtyPasswordIds.subtract(processedDirtyPasswordIds)
            } else if let pushUrl = URL(string: "\(serverUrl)/api/sync/push"),
                      let body = outbound.encodedBody {
                var pushReq = URLRequest(url: pushUrl)
                pushReq.httpMethod = "POST"
                pushReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                pushReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                pushReq.httpBody = body
                let (_, pushResp) = try await URLSession.shared.data(for: pushReq)
                if let pHttp = pushResp as? HTTPURLResponse, pHttp.statusCode == 200 {
                    dirtyScopes.subtract(processedDirtyScopes)
                    dirtyBookmarkIds.subtract(processedDirtyBookmarkIds)
                    dirtyPasswordIds.subtract(processedDirtyPasswordIds)
                    for (k, v) in outbound.updatedHashes {
                        lastPushedHashes[k] = v
                    }
                    for delKey in outbound.deletedKeys {
                        lastPushedHashes.removeValue(forKey: delKey)
                    }
                    if !outbound.deletedKeys.isEmpty {
                        pendingTombstones.removeAll { outbound.deletedKeys.contains("\($0.scope)|\($0.itemId)") }
                    }
                    pruneStalePushedHashes()
                }
            }

            let nowMs = (decoded.serverTime ?? Date().timeIntervalSince1970 * 1000)
            lastPulledAt = max(lastPulledAt, nowMs)
            lastSyncedAt = Date().timeIntervalSince1970 * 1000

            if var disk = CryptoVault.loadSession() {
                disk.lastPulledAt = lastPulledAt
                disk.lastSyncedAt = lastSyncedAt
                CryptoVault.saveSession(disk)
            }
            saveLocalCache()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func buildCurrentPortableSettings() -> PortableSettings {
        let storedBlockAppJumps = UserDefaults.standard.object(forKey: "prism.blockRogueAppJumps") != nil
            ? UserDefaults.standard.bool(forKey: "prism.blockRogueAppJumps")
            : true
        let storedEnterTopHit = UserDefaults.standard.object(forKey: "prism.omniboxEnterTopHitEnabled") != nil
            ? UserDefaults.standard.bool(forKey: "prism.omniboxEnterTopHitEnabled")
            : false
        let storedTheme = UserDefaults.standard.string(forKey: "prism.theme")
            .flatMap { AppTheme(rawValue: $0) }
        let storedEngine = UserDefaults.standard.string(forKey: "prism.searchEngine")
            .flatMap { SearchEngineOption(rawValue: $0) }
        return PortableSettings(
            language: L10n.isEnglish ? .en : .zhCN,
            theme: storedTheme,
            searchEngine: storedEngine,
            defaultProxyMode: nil,
            stripTrackingParams: nil,
            autoSyncIntervalMinutes: autoSyncIntervalMinutes,
            builtInAdblockEnabled: nil,
            blockRogueAppJumps: storedBlockAppJumps,
            omniboxEnterTopHitEnabled: storedEnterTopHit
        )
    }

    private func pruneStalePushedHashes() {
        // Prevent unbounded hash dictionary growth if user visits thousands of URLs over months
        if lastPushedHashes.count <= 2000 { return }
        var keep = Set<String>()
        keep.insert("home_shortcuts|home:config")
        keep.insert("settings|settings:portable")
        for bm in bookmarks { keep.insert("bookmarks|\(Self.bookmarkSyncIdStatic(bm))") }
        for pw in passwords { keep.insert("passwords|password:\(pw.id)") }
        for prof in profiles { keep.insert("profiles|profile:\(prof.id)") }
        for h in history.prefix(500) { keep.insert("history|\(Self.historySyncIdStatic(url: h.url))") }
        lastPushedHashes = lastPushedHashes.filter { keep.contains($0.key) }
    }

    nonisolated private static func contentHash<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return CryptoVault.sha1Hex(str)
    }

    nonisolated private static func historySyncIdStatic(url: String) -> String {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return "history:\(CryptoVault.sha1Hex(clean))"
    }

    nonisolated private static func bookmarkSyncIdStatic(_ bm: BookmarkItem) -> String {
        if bm.type == "folder" {
            return "bookmark:folder:\(bm.id)"
        }
        return "bookmark:\(CryptoVault.sha1Hex(bm.url))"
    }

    nonisolated private static func decryptPulledItems(
        _ items: [SyncItemPayload],
        encKey: Data,
        scopes: SyncScopeToggles,
        pendingTombstones: [SyncTombstone]
    ) -> DecryptedPullBatch {
        var batch = DecryptedPullBatch()
        let tombstoneMap = Dictionary(
            pendingTombstones.map { ("\($0.scope)|\($0.itemId)", $0.updatedAt) },
            uniquingKeysWith: { max($0, $1) }
        )

        for item in items {
            if let deletedAt = tombstoneMap["\(item.scope)|\(item.itemId)"], item.updatedAt <= deletedAt {
                continue
            }
            switch item.scope {
            case "bookmarks" where scopes.bookmarks:
                if item.deleted {
                    batch.deletedBookmarkIds.append(item.itemId)
                } else if let bm = try? CryptoVault.decryptJSON(BookmarkItem.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    batch.upsertedBookmarks.append(bm)
                    if let h = contentHash(bm) {
                        batch.syncedHashes["bookmarks|\(bookmarkSyncIdStatic(bm))"] = h
                    }
                }
            case "passwords" where scopes.passwords:
                if item.deleted {
                    batch.deletedPasswordRawIds.append(item.itemId.replacingOccurrences(of: "password:", with: ""))
                } else if let pw = try? CryptoVault.decryptJSON(PasswordEntry.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    batch.upsertedPasswords.append(pw)
                    if let h = contentHash(pw) {
                        batch.syncedHashes["passwords|password:\(pw.id)"] = h
                    }
                }
            case "home_shortcuts" where scopes.home_shortcuts && item.itemId == "home:config" && !item.deleted:
                struct HomePayload: Decodable {
                    let homeConfig: HomeConfig?
                }
                if let wrapped = try? CryptoVault.decryptJSON(HomePayload.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag),
                   let remoteHome = wrapped.homeConfig {
                    batch.remoteHomeConfig = remoteHome
                    if let h = contentHash(remoteHome) {
                        batch.syncedHashes["home_shortcuts|home:config"] = h
                    }
                }
            case "profiles" where scopes.profiles:
                if item.deleted {
                    let rawId = item.itemId.hasPrefix("profile:")
                        ? String(item.itemId.dropFirst("profile:".count))
                        : item.itemId
                    batch.deletedProfileRawIds.append(rawId)
                } else if let prof = try? CryptoVault.decryptJSON(BrowserProfile.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    batch.upsertedProfiles.append(prof)
                    if let h = contentHash(prof) {
                        batch.syncedHashes["profiles|profile:\(prof.id)"] = h
                    }
                }
            case "history" where scopes.history:
                if item.deleted {
                    batch.deletedHistoryItems.append((item.itemId, item.updatedAt))
                } else if let hist = try? CryptoVault.decryptJSON(HistoryItem.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    batch.upsertedHistory.append(hist)
                    if let h = contentHash(hist) {
                        batch.syncedHashes["history|\(historySyncIdStatic(url: hist.url))"] = h
                    }
                }
            case "settings" where scopes.settings && item.itemId == "settings:portable" && !item.deleted:
                struct SettingsWrap: Decodable {
                    let settings: PortableSettings?
                }
                if let wrap = try? CryptoVault.decryptJSON(SettingsWrap.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag),
                   let remote = wrap.settings {
                    batch.remotePortableSettings = remote
                    if let h = contentHash(remote) {
                        batch.syncedHashes["settings|settings:portable"] = h
                    }
                }
            default:
                break
            }
        }
        return batch
    }

    private func applyDecryptedPullBatch(_ batch: DecryptedPullBatch) {
        var bmMap = Dictionary(uniqueKeysWithValues: bookmarks.map { (bookmarkSyncId($0), $0) })
        var bmChanged = false
        for delId in batch.deletedBookmarkIds {
            if bmMap.removeValue(forKey: delId) != nil { bmChanged = true }
            lastPushedHashes.removeValue(forKey: "bookmarks|\(delId)")
        }
        for bm in batch.upsertedBookmarks {
            let key = bookmarkSyncId(bm)
            let existingTs = bmMap[key]?.updatedAt ?? bmMap[key]?.createdAt ?? 0
            if (bm.updatedAt ?? bm.createdAt) >= existingTs {
                bmMap[key] = bm
                bmChanged = true
            }
        }

        var pwMap = Dictionary(uniqueKeysWithValues: passwords.map { ($0.id, $0) })
        var pwChanged = false
        for rawId in batch.deletedPasswordRawIds {
            if pwMap.removeValue(forKey: rawId) != nil { pwChanged = true }
            lastPushedHashes.removeValue(forKey: "passwords|password:\(rawId)")
        }
        for pw in batch.upsertedPasswords {
            if let old = pwMap[pw.id] {
                if pw.updatedAt > old.updatedAt {
                    pwMap[pw.id] = pw
                    pwChanged = true
                }
            } else {
                pwMap[pw.id] = pw
                pwChanged = true
            }
        }

        if let remoteHome = batch.remoteHomeConfig {
            homeConfig = remoteHome
        }

        var profMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var profChanged = false
        for rawId in batch.deletedProfileRawIds {
            if rawId != "default", profMap.removeValue(forKey: rawId) != nil {
                profChanged = true
            }
            lastPushedHashes.removeValue(forKey: "profiles|profile:\(rawId)")
        }
        for prof in batch.upsertedProfiles {
            profMap[prof.id] = prof
            profChanged = true
        }

        var histMap = Dictionary(uniqueKeysWithValues: history.map { ($0.url, $0) })
        var histChanged = false
        for del in batch.deletedHistoryItems {
            for (u, h) in histMap where historySyncId(url: u) == del.itemId && del.updatedAt >= h.visitedAt {
                histMap.removeValue(forKey: u)
                histChanged = true
            }
            lastPushedHashes.removeValue(forKey: "history|\(del.itemId)")
        }
        for hist in batch.upsertedHistory {
            if (histMap[hist.url]?.visitedAt ?? 0) < hist.visitedAt {
                histMap[hist.url] = hist
                histChanged = true
            }
        }

        if let remote = batch.remotePortableSettings {
            if let freq = remote.autoSyncIntervalMinutes, freq != autoSyncIntervalMinutes {
                autoSyncIntervalMinutes = freq
                UserDefaults.standard.set(freq, forKey: "prism.autoSyncInterval")
                rescheduleAutoSync()
            }
            if let blockJumps = remote.blockRogueAppJumps {
                UserDefaults.standard.set(blockJumps, forKey: "prism.blockRogueAppJumps")
            }
            onRemotePortableSettings?(remote)
        }

        for (k, v) in batch.syncedHashes {
            lastPushedHashes[k] = v
        }

        if bmChanged {
            bookmarks = bmMap.values.sorted { ($0.order ?? 0, $0.createdAt) < ($1.order ?? 0, $1.createdAt) }
        }
        if pwChanged {
            passwords = pwMap.values.sorted { $0.updatedAt > $1.updatedAt }
        }
        if histChanged {
            history = histMap.values.sorted { $0.visitedAt > $1.visitedAt }
        }
        if profChanged {
            profiles = profMap.values.sorted { $0.createdAt < $1.createdAt }
        }
    }

    nonisolated private static func buildOutboundPayload(
        encKey: Data,
        targetScopes: Set<String>,
        targetBookmarkIds: Set<String>,
        targetPasswordIds: Set<String>,
        scopes: SyncScopeToggles,
        bookmarks: [BookmarkItem],
        passwords: [PasswordEntry],
        history: [HistoryItem],
        profiles: [BrowserProfile],
        homeConfig: HomeConfig,
        pendingTombstones: [SyncTombstone],
        portableSettings: PortableSettings,
        lastPushedHashes: [String: String]
    ) -> OutboundSyncBuildResult {
        var out: [SyncItemPayload] = []
        var updatedHashes: [String: String] = [:]
        var deletedKeys = Set<String>()
        let nowMs = Date().timeIntervalSince1970 * 1000

        if targetScopes.contains("home_shortcuts") && scopes.home_shortcuts {
            struct HomePayload: Encodable {
                let homeConfig: HomeConfig
                let updatedAt: Double
            }
            let hashKey = "home_shortcuts|home:config"
            let h = contentHash(homeConfig)
            if h == nil || lastPushedHashes[hashKey] != h,
               let env = try? CryptoVault.encryptJSON(HomePayload(homeConfig: homeConfig, updatedAt: nowMs), encKey: encKey) {
                out.append(SyncItemPayload(scope: "home_shortcuts", itemId: "home:config", iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: nowMs))
                if let h { updatedHashes[hashKey] = h }
            }
        }
        if targetScopes.contains("bookmarks") && scopes.bookmarks {
            let targets: [BookmarkItem] = targetBookmarkIds.isEmpty
                ? bookmarks
                : bookmarks.filter { targetBookmarkIds.contains($0.id) || targetBookmarkIds.contains(bookmarkSyncIdStatic($0)) }
            for bm in targets {
                let itemId = bookmarkSyncIdStatic(bm)
                let hashKey = "bookmarks|\(itemId)"
                let h = contentHash(bm)
                if let h, lastPushedHashes[hashKey] == h { continue }
                if let env = try? CryptoVault.encryptJSON(bm, encKey: encKey) {
                    out.append(SyncItemPayload(scope: "bookmarks", itemId: itemId, iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: bm.updatedAt ?? nowMs))
                    if let h { updatedHashes[hashKey] = h }
                }
            }
        }
        if targetScopes.contains("passwords") && scopes.passwords {
            let targets: [PasswordEntry] = targetPasswordIds.isEmpty
                ? passwords
                : passwords.filter { targetPasswordIds.contains($0.id) }
            for pw in targets {
                let itemId = "password:\(pw.id)"
                let hashKey = "passwords|\(itemId)"
                let h = contentHash(pw)
                if let h, lastPushedHashes[hashKey] == h { continue }
                if let env = try? CryptoVault.encryptJSON(pw, encKey: encKey) {
                    out.append(SyncItemPayload(scope: "passwords", itemId: itemId, iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: pw.updatedAt))
                    if let h { updatedHashes[hashKey] = h }
                }
            }
        }
        if targetScopes.contains("history") && scopes.history {
            let cutoffMs = nowMs - (30.0 * 24.0 * 60.0 * 60.0 * 1000.0)
            var dedupedByUrl: [String: HistoryItem] = [:]
            for h in history {
                let cleanUrl = h.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanUrl.isEmpty, h.visitedAt >= cutoffMs else { continue }
                if let existing = dedupedByUrl[cleanUrl], existing.visitedAt >= h.visitedAt {
                    continue
                }
                var copy = h
                copy.url = cleanUrl
                dedupedByUrl[cleanUrl] = copy
            }
            let recentUnique = dedupedByUrl.values
                .sorted { $0.visitedAt > $1.visitedAt }
                .prefix(500)
            for h in recentUnique {
                let itemId = historySyncIdStatic(url: h.url)
                let hashKey = "history|\(itemId)"
                let digest = contentHash(h)
                // Incremental delta check: only encrypt & upload history items that actually changed
                if let digest, lastPushedHashes[hashKey] == digest { continue }
                if let env = try? CryptoVault.encryptJSON(h, encKey: encKey) {
                    out.append(SyncItemPayload(scope: "history", itemId: itemId, iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: h.visitedAt > 0 ? h.visitedAt : nowMs))
                    if let digest { updatedHashes[hashKey] = digest }
                }
            }
        }
        if !pendingTombstones.isEmpty {
            struct TombstonePayload: Encodable {
                let deleted: Bool
                let deletedAt: Double
            }
            for tomb in pendingTombstones {
                let allowed: Bool = {
                    switch tomb.scope {
                    case "bookmarks": return scopes.bookmarks
                    case "passwords": return scopes.passwords
                    case "profiles": return scopes.profiles
                    case "history": return scopes.history
                    default: return true
                    }
                }()
                guard allowed,
                      let env = try? CryptoVault.encryptJSON(TombstonePayload(deleted: true, deletedAt: tomb.updatedAt), encKey: encKey) else {
                    continue
                }
                out.append(SyncItemPayload(scope: tomb.scope, itemId: tomb.itemId, iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: true, updatedAt: tomb.updatedAt))
                deletedKeys.insert("\(tomb.scope)|\(tomb.itemId)")
            }
        }
        if targetScopes.contains("profiles") && scopes.profiles {
            for prof in profiles {
                let itemId = "profile:\(prof.id)"
                let hashKey = "profiles|\(itemId)"
                let h = contentHash(prof)
                if let h, lastPushedHashes[hashKey] == h { continue }
                if let env = try? CryptoVault.encryptJSON(prof, encKey: encKey) {
                    out.append(SyncItemPayload(scope: "profiles", itemId: itemId, iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: nowMs))
                    if let h { updatedHashes[hashKey] = h }
                }
            }
        }
        if targetScopes.contains("settings") && scopes.settings {
            struct SettingsPayload: Encodable {
                let settings: PortableSettings
                let updatedAt: Double
            }
            let hashKey = "settings|settings:portable"
            let h = contentHash(portableSettings)
            if h == nil || lastPushedHashes[hashKey] != h,
               let env = try? CryptoVault.encryptJSON(SettingsPayload(settings: portableSettings, updatedAt: nowMs), encKey: encKey) {
                out.append(SyncItemPayload(scope: "settings", itemId: "settings:portable", iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: nowMs))
                if let h { updatedHashes[hashKey] = h }
            }
        }

        let body = out.isEmpty ? nil : (try? JSONEncoder().encode(["items": out]))
        return OutboundSyncBuildResult(
            items: out,
            encodedBody: body,
            updatedHashes: updatedHashes,
            deletedKeys: deletedKeys
        )
    }

    func markBookmarkChanged(_ bm: BookmarkItem) {
        let syncId = bookmarkSyncId(bm)
        if let idx = bookmarks.firstIndex(where: { $0.id == bm.id || bookmarkSyncId($0) == syncId }) {
            bookmarks[idx] = bm
        } else {
            bookmarks.append(bm)
        }
        dirtyBookmarkIds.insert(bm.id)
        pendingTombstones.removeAll { $0.scope == "bookmarks" && $0.itemId == syncId }
        saveLocalCache()
        notifyScopeDirty("bookmarks")
    }

    func recordDeletedBookmark(_ bm: BookmarkItem) {
        let syncId = bookmarkSyncId(bm)
        let nowMs = Date().timeIntervalSince1970 * 1000
        bookmarks.removeAll { $0.id == bm.id || bookmarkSyncId($0) == syncId }
        dirtyBookmarkIds.remove(bm.id)
        pendingTombstones.removeAll { $0.scope == "bookmarks" && $0.itemId == syncId }
        pendingTombstones.append(SyncTombstone(scope: "bookmarks", itemId: syncId, updatedAt: nowMs))
        saveLocalCache()
        notifyScopeDirty("bookmarks")
    }

    func markPasswordChanged(_ pw: PasswordEntry) {
        if let idx = passwords.firstIndex(where: { $0.id == pw.id }) {
            passwords[idx] = pw
        } else {
            passwords.insert(pw, at: 0)
        }
        dirtyPasswordIds.insert(pw.id)
        pendingTombstones.removeAll { $0.scope == "passwords" && $0.itemId == "password:\(pw.id)" }
        saveLocalCache()
        notifyScopeDirty("passwords")
    }

    func recordDeletedPassword(_ pw: PasswordEntry) {
        let syncId = "password:\(pw.id)"
        let nowMs = Date().timeIntervalSince1970 * 1000
        passwords.removeAll { $0.id == pw.id }
        dirtyPasswordIds.remove(pw.id)
        pendingTombstones.removeAll { $0.scope == "passwords" && $0.itemId == syncId }
        pendingTombstones.append(SyncTombstone(scope: "passwords", itemId: syncId, updatedAt: nowMs))
        saveLocalCache()
        notifyScopeDirty("passwords")
    }

    func recordHistoryVisit(_ item: HistoryItem) {
        let cleanUrl = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUrl.isEmpty else { return }
        let syncId = historySyncId(url: cleanUrl)
        var normalized = item
        normalized.url = cleanUrl
        history.removeAll { $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == cleanUrl }
        history.insert(normalized, at: 0)
        if history.count > 500 {
            history = Array(history.prefix(500))
        }
        pendingTombstones.removeAll { $0.scope == "history" && $0.itemId == syncId }
        notifyScopeDirty("history")
    }

    func recordDeletedHistory(_ item: HistoryItem) {
        let cleanUrl = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let syncId = historySyncId(url: cleanUrl)
        let nowMs = Date().timeIntervalSince1970 * 1000
        history.removeAll {
            $0.id == item.id || $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == cleanUrl
        }
        pendingTombstones.removeAll { $0.scope == "history" && $0.itemId == syncId }
        pendingTombstones.append(SyncTombstone(scope: "history", itemId: syncId, updatedAt: nowMs))
        saveLocalCache()
        notifyScopeDirty("history")
    }

    func recordClearedHistory() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let previous = history
        history.removeAll()
        for item in previous {
            let syncId = historySyncId(url: item.url)
            pendingTombstones.removeAll { $0.scope == "history" && $0.itemId == syncId }
            pendingTombstones.append(SyncTombstone(scope: "history", itemId: syncId, updatedAt: nowMs))
        }
        saveLocalCache()
        notifyScopeDirty("history")
    }

    private func historySyncId(url: String) -> String {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return "history:\(CryptoVault.sha1Hex(clean))"
    }

    private func bookmarkSyncId(_ bm: BookmarkItem) -> String {
        if bm.type == "folder" {
            return "bookmark:folder:\(bm.id)"
        }
        return "bookmark:\(CryptoVault.sha1Hex(bm.url))"
    }

    // MARK: - Local JSON Cache

    func saveLocalCache() {
        let snap = SyncDiskSnapshot(
            bookmarks: bookmarks,
            passwords: passwords,
            history: Array(history.prefix(500)),
            homeConfig: homeConfig,
            profiles: profiles,
            pendingTombstones: pendingTombstones,
            lastPushedHashes: lastPushedHashes
        )
        let url = cacheDir.appendingPathComponent("vault-state.json")
        let writer = cacheWriter
        Task.detached(priority: .utility) {
            await writer.write(snap, to: url)
        }
    }

    private func loadLocalCache() {
        let url = cacheDir.appendingPathComponent("vault-state.json")
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(SyncDiskSnapshot.self, from: data) else { return }
        self.bookmarks = snap.bookmarks
        self.passwords = snap.passwords
        self.history = snap.history
        self.homeConfig = snap.homeConfig
        if !snap.profiles.isEmpty {
            self.profiles = snap.profiles
        }
        self.pendingTombstones = snap.pendingTombstones ?? []
        self.lastPushedHashes = snap.lastPushedHashes ?? [:]
    }
}
