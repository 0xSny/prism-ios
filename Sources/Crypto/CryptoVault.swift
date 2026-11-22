import CommonCrypto
import CryptoKit
import Foundation
import Security

enum CryptoVaultError: Error, LocalizedError {
    case pbkdf2Failed
    case invalidKey
    case invalidCiphertext
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .pbkdf2Failed: return "Key derivation failed"
        case .invalidKey: return "Invalid AES-256 encryption key"
        case .invalidCiphertext: return "Invalid encrypted payload"
        case .encodingFailed: return "Failed to encode JSON payload"
        }
    }
}

enum CryptoVault {
    static let pbkdf2Iterations: UInt32 = 600_000
    static let keyLengthBytes = 32
    static let keychainService = "com.zzaoo.prism.mobile.vault"
    static let sessionAccountKey = "account-session"

    static func generateSaltBase64Url(bytes: Int = 16) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64UrlEncode(data)
    }

    static func deriveKeys(masterPassword: String, kdfSalt: String) throws -> (authKey: String, encKey: Data) {
        let saltString = "prism-v1:\(kdfSalt)"
        guard let passwordData = masterPassword.data(using: .utf8),
              let saltData = saltString.data(using: .utf8) else {
            throw CryptoVaultError.encodingFailed
        }

        var masterKey = Data(count: keyLengthBytes)
        let status = masterKey.withUnsafeMutableBytes { derivedPtr in
            saltData.withUnsafeBytes { saltPtr in
                passwordData.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress,
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress,
                        keyLengthBytes
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw CryptoVaultError.pbkdf2Failed
        }

        let inputKey = SymmetricKey(data: masterKey)
        let authInfo = Data("prism-server-auth-v1".utf8)
        let encInfo = Data("prism-vault-enc-v1".utf8)

        let authSymmetric = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(),
            info: authInfo,
            outputByteCount: keyLengthBytes
        )
        let encSymmetric = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(),
            info: encInfo,
            outputByteCount: keyLengthBytes
        )

        let authBytes = authSymmetric.withUnsafeBytes { Data($0) }
        let encBytes = encSymmetric.withUnsafeBytes { Data($0) }
        return (base64UrlEncode(authBytes), encBytes)
    }

    static func encryptJSON<T: Encodable>(_ value: T, encKey: Data) throws -> EncryptedEnvelope {
        guard encKey.count == keyLengthBytes else { throw CryptoVaultError.invalidKey }
        let plaintext = try JSONEncoder().encode(value)
        let key = SymmetricKey(data: encKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let ivData = sealed.nonce.withUnsafeBytes { Data($0) }
        return EncryptedEnvelope(
            iv: ivData.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
    }

    static func decryptJSON<T: Decodable>(
        _ type: T.Type,
        encKey: Data,
        ivB64: String,
        ciphertextB64: String,
        tagB64: String
    ) throws -> T {
        guard encKey.count == keyLengthBytes else { throw CryptoVaultError.invalidKey }
        guard let ivData = Data(base64Encoded: ivB64),
              let cipherData = Data(base64Encoded: ciphertextB64),
              let tagData = Data(base64Encoded: tagB64) else {
            throw CryptoVaultError.invalidCiphertext
        }
        let nonce = try AES.GCM.Nonce(data: ivData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData)
        let decrypted = try AES.GCM.open(sealedBox, using: SymmetricKey(data: encKey))
        return try JSONDecoder().decode(T.self, from: decrypted)
    }

    static func sha1Hex(_ input: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func generateRecoveryKey24() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, 24, &bytes)
        let raw = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 24, by: 4)
            .map { String(raw[$0..<min($0 + 4, 24)]) }
            .joined(separator: "-")
    }

    static func deriveRecoveryWrapKey(recoveryKey: String, email: String) -> Data {
        let cleaned = recoveryKey
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        let sha = Data(SHA256.hash(data: Data(cleaned.utf8)))
        let sym = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sha),
            salt: Data("prism-recovery-wrap-v1".utf8),
            info: Data(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8),
            outputByteCount: keyLengthBytes
        )
        return sym.withUnsafeBytes { Data($0) }
    }

    static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain Persistence

    static func saveSession(_ session: AccountSessionDisk) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: sessionAccountKey,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func loadSession() -> AccountSessionDisk? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: sessionAccountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AccountSessionDisk.self, from: data)
    }

    static func clearSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: sessionAccountKey,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
