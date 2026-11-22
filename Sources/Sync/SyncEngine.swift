import CryptoKit
import Foundation
import UIKit

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
    private var debounceTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?

    private let cacheDir: URL

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
                "appVersion": "1.0.6",
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
                "appVersion": "1.0.6",
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
                "appVersion": "1.0.6",
            ]

            let cleanRec = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanRec.isEmpty, let prepUrl = URL(string: "\(serverUrl)/api/auth/reset-prepare") {
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
                    let recoveryBlob: EncryptedEnvelope?
                    let items: [PrepItem]?
                }
                if let pHttp = pResp as? HTTPURLResponse, pHttp.statusCode == 200,
                   let prep = try? JSONDecoder().decode(PrepResp.self, from: pData),
                   let blob = prep.recoveryBlob {
                    struct DecWrap: Decodable { let encKeyB64: String }
                    struct EncWrap: Encodable { let encKeyB64: String; let v: Int }
                    let wrapKey = CryptoVault.deriveRecoveryWrapKey(recoveryKey: cleanRec, email: cleanEmail)
                    let dec = try CryptoVault.decryptJSON(DecWrap.self, encKey: wrapKey, ivB64: blob.iv, ciphertextB64: blob.ciphertext, tagB64: blob.tag)
                    if let oldKey = Data(base64Encoded: dec.encKeyB64), oldKey.count == 32 {
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
                }
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
            applyPulledItems(decoded.items, encKey: encKey)

            let pushItems = buildOutboundItems(encKey: encKey)
            if !pushItems.isEmpty, let pushUrl = URL(string: "\(serverUrl)/api/sync/push") {
                var pushReq = URLRequest(url: pushUrl)
                pushReq.httpMethod = "POST"
                pushReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                pushReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body = try JSONEncoder().encode(["items": pushItems])
                pushReq.httpBody = body
                let (_, pushResp) = try await URLSession.shared.data(for: pushReq)
                if let pHttp = pushResp as? HTTPURLResponse, pHttp.statusCode == 200 {
                    dirtyScopes.removeAll()
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

    private func applyPulledItems(_ items: [SyncItemPayload], encKey: Data) {
        var bmMap = Dictionary(uniqueKeysWithValues: bookmarks.map { (bookmarkSyncId($0), $0) })
        var bmChanged = false
        var pwMap = Dictionary(uniqueKeysWithValues: passwords.map { ($0.id, $0) })
        var pwChanged = false
        var histMap = Dictionary(uniqueKeysWithValues: history.map { ($0.url, $0) })
        var histChanged = false
        var profMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var profChanged = false

        for item in items {
            switch item.scope {
            case "bookmarks" where scopes.bookmarks:
                if item.deleted {
                    if bmMap.removeValue(forKey: item.itemId) != nil { bmChanged = true }
                } else if let bm = try? CryptoVault.decryptJSON(BookmarkItem.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    let key = bookmarkSyncId(bm)
                    let existingTs = bmMap[key]?.updatedAt ?? bmMap[key]?.createdAt ?? 0
                    if (bm.updatedAt ?? bm.createdAt) >= existingTs {
                        bmMap[key] = bm
                        bmChanged = true
                    }
                }
            case "passwords" where scopes.passwords:
                if item.deleted {
                    let rawId = item.itemId.replacingOccurrences(of: "password:", with: "")
                    if pwMap.removeValue(forKey: rawId) != nil { pwChanged = true }
                } else if let pw = try? CryptoVault.decryptJSON(PasswordEntry.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
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
            case "home_shortcuts" where scopes.home_shortcuts && item.itemId == "home:config" && !item.deleted:
                struct HomePayload: Decodable {
                    let homeConfig: HomeConfig?
                }
                if let wrapped = try? CryptoVault.decryptJSON(HomePayload.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag),
                   let remoteHome = wrapped.homeConfig {
                    homeConfig = remoteHome
                }
            case "profiles" where scopes.profiles:
                if let prof = try? CryptoVault.decryptJSON(BrowserProfile.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    profMap[prof.id] = prof
                    profChanged = true
                }
            case "history" where scopes.history && !item.deleted:
                if let hist = try? CryptoVault.decryptJSON(HistoryItem.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag) {
                    if (histMap[hist.url]?.visitedAt ?? 0) < hist.visitedAt {
                        histMap[hist.url] = hist
                        histChanged = true
                    }
                }
            case "settings" where scopes.settings && item.itemId == "settings:portable" && !item.deleted:
                struct SettingsWrap: Decodable {
                    let settings: PortableSettings?
                }
                if let wrap = try? CryptoVault.decryptJSON(SettingsWrap.self, encKey: encKey, ivB64: item.iv, ciphertextB64: item.ciphertext, tagB64: item.tag),
                   let remote = wrap.settings {
                    if let freq = remote.autoSyncIntervalMinutes, freq != autoSyncIntervalMinutes {
                        autoSyncIntervalMinutes = freq
                        UserDefaults.standard.set(freq, forKey: "prism.autoSyncInterval")
                        rescheduleAutoSync()
                    }
                }
            default:
                break
            }
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

    private func buildOutboundItems(encKey: Data) -> [SyncItemPayload] {
        var out: [SyncItemPayload] = []
        let nowMs = Date().timeIntervalSince1970 * 1000

        if dirtyScopes.contains("home_shortcuts") && scopes.home_shortcuts {
            struct HomePayload: Encodable {
                let homeConfig: HomeConfig
                let updatedAt: Double
            }
            if let env = try? CryptoVault.encryptJSON(HomePayload(homeConfig: homeConfig, updatedAt: nowMs), encKey: encKey) {
                out.append(SyncItemPayload(scope: "home_shortcuts", itemId: "home:config", iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: nowMs))
            }
        }
        if dirtyScopes.contains("bookmarks") && scopes.bookmarks {
            for bm in bookmarks.suffix(40) {
                if let env = try? CryptoVault.encryptJSON(bm, encKey: encKey) {
                    out.append(SyncItemPayload(scope: "bookmarks", itemId: bookmarkSyncId(bm), iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: bm.updatedAt ?? nowMs))
                }
            }
        }
        if dirtyScopes.contains("passwords") && scopes.passwords {
            for pw in passwords.prefix(40) {
                if let env = try? CryptoVault.encryptJSON(pw, encKey: encKey) {
                    out.append(SyncItemPayload(scope: "passwords", itemId: "password:\(pw.id)", iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: pw.updatedAt))
                }
            }
        }
        if dirtyScopes.contains("profiles") && scopes.profiles {
            for prof in profiles {
                if let env = try? CryptoVault.encryptJSON(prof, encKey: encKey) {
                    out.append(SyncItemPayload(scope: "profiles", itemId: "profile:\(prof.id)", iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: nowMs))
                }
            }
        }
        if dirtyScopes.contains("settings") && scopes.settings {
            struct SettingsPayload: Encodable {
                let settings: PortableSettings
                let updatedAt: Double
            }
            let portable = PortableSettings(
                language: L10n.isEnglish ? .en : .zhCN,
                theme: nil,
                searchEngine: nil,
                defaultProxyMode: nil,
                stripTrackingParams: nil,
                autoSyncIntervalMinutes: autoSyncIntervalMinutes,
                builtInAdblockEnabled: nil,
                blockRogueAppJumps: nil
            )
            if let env = try? CryptoVault.encryptJSON(SettingsPayload(settings: portable, updatedAt: nowMs), encKey: encKey) {
                out.append(SyncItemPayload(scope: "settings", itemId: "settings:portable", iv: env.iv, ciphertext: env.ciphertext, tag: env.tag, deleted: false, updatedAt: nowMs))
            }
        }
        return out
    }

    private func bookmarkSyncId(_ bm: BookmarkItem) -> String {
        if bm.type == "folder" {
            return "bookmark:folder:\(bm.id)"
        }
        return "bookmark:\(CryptoVault.sha1Hex(bm.url))"
    }

    // MARK: - Local JSON Cache

    private struct DiskSnapshot: Codable {
        var bookmarks: [BookmarkItem]
        var passwords: [PasswordEntry]
        var history: [HistoryItem]
        var homeConfig: HomeConfig
        var profiles: [BrowserProfile]
    }

    func saveLocalCache() {
        let snap = DiskSnapshot(
            bookmarks: bookmarks,
            passwords: passwords,
            history: Array(history.prefix(500)),
            homeConfig: homeConfig,
            profiles: profiles
        )
        let url = cacheDir.appendingPathComponent("vault-state.json")
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadLocalCache() {
        let url = cacheDir.appendingPathComponent("vault-state.json")
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(DiskSnapshot.self, from: data) else { return }
        self.bookmarks = snap.bookmarks
        self.passwords = snap.passwords
        self.history = snap.history
        self.homeConfig = snap.homeConfig
        if !snap.profiles.isEmpty {
            self.profiles = snap.profiles
        }
    }
}
