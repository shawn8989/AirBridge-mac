//
//  SecurityManager.swift
//  AirBridge
//
//  Handles Keychain storage, HMAC verification, and pairing.
//

import Foundation
import CryptoKit
import Security

enum SecurityError: Error {
    case keychainFailure(OSStatus)
    case missingSecret
    case invalidHMAC
    case staleTimestamp
}

final class SecurityManager {
    private let service = "com.example.AirBridge.sharedSecrets"

    // Generate a 256-bit shared secret
    func generateSharedSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
    }

    func storeSharedSecret(_ secret: Data, for deviceID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecurityError.keychainFailure(status) }
    }

    func loadSharedSecret(for deviceID: String) throws -> Data {        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw SecurityError.missingSecret }
        return data
    }

    /// Removes the stored shared secret for a device, e.g. after an auth failure
    /// so the next connection performs a fresh pairing.
    func deleteSharedSecret(for deviceID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID
        ]
        SecItemDelete(query as CFDictionary)
    }

    // Compute HMAC-SHA256 over canonical JSON payload bytes
    func computeHMAC(secret: Data, data: Data) -> Data {
        let key = SymmetricKey(data: secret)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac)
    }

    /// Generate a random nonce (default 16 bytes)
    func generateNonce(length: Int = 16) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(1, length))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
    }

    private func encodeUInt64BE(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    /// Build canonical HMAC input: type (utf8) + payloadJSON (sorted keys) + nonce + ts(8 bytes BE) + ctr(8 bytes BE)
    func makeHMACInput(type: String, payloadJSON: Data, nonce: Data, ts: UInt64, ctr: UInt64) -> Data {
        var data = Data()
        if let typeData = type.data(using: .utf8) { data.append(typeData) }
        data.append(payloadJSON)
        data.append(nonce)
        data.append(encodeUInt64BE(ts))
        data.append(encodeUInt64BE(ctr))
        return data
    }

    /// Sign the canonical input and return Base64-encoded HMAC
    func signHMACBase64(secret: Data, type: String, payloadJSON: Data, nonce: Data, ts: UInt64, ctr: UInt64) -> String {
        let input = makeHMACInput(type: type, payloadJSON: payloadJSON, nonce: nonce, ts: ts, ctr: ctr)
        let mac = computeHMAC(secret: secret, data: input)
        return mac.base64EncodedString()
    }

    /// Verify Base64 HMAC for the given fields
    func verifyHMACBase64(secret: Data, type: String, payloadJSON: Data, nonce: Data, ts: UInt64, ctr: UInt64, hmacB64: String) -> Bool {
        guard let received = Data(base64Encoded: hmacB64) else { return false }
        let input = makeHMACInput(type: type, payloadJSON: payloadJSON, nonce: nonce, ts: ts, ctr: ctr)
        let expected = computeHMAC(secret: secret, data: input)
        return expected == received
    }

    func verify(packet: AirPacketRaw, secret: Data) throws {
        // Timestamp freshness: within 3 seconds
        let now = Date().timeIntervalSince1970
        guard abs(now - packet.timestamp) <= 3 else { throw SecurityError.staleTimestamp }

        // Reconstruct canonical data without hmac
        let canonical = packet.canonicalDataForHMAC()
        let expected = computeHMAC(secret: secret, data: canonical)
        guard expected == packet.hmac else { throw SecurityError.invalidHMAC }
    }

    private let serverIdentityLabel = "AirBridge Server Identity"

    // Attempt to load a server identity (certificate + private key) from the Keychain by label.
    // You can create/import a self-signed identity via Keychain Access and set its label to match serverIdentityLabel.
    func loadServerIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrLabel as String: serverIdentityLabel
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let cf = result else { return nil }
        let identity = cf as! SecIdentity
        return identity
    }

    // Extract certificate from identity
    func certificate(from identity: SecIdentity) -> SecCertificate? {
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &cert)
        guard status == errSecSuccess else { return nil }
        return cert
    }

    // DER data for a certificate
    func certificateData(_ cert: SecCertificate) -> Data? {
        return SecCertificateCopyData(cert) as Data
    }

    // SHA-256 fingerprint (hex) of the certificate DER
    func certificateFingerprintSHA256(_ cert: SecCertificate) -> String? {
        guard let der = certificateData(cert) else { return nil }
        let digest = SHA256.hash(data: der)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // Export the public key bytes from a certificate if possible (DER-encoded SubjectPublicKeyInfo)
    func publicKeyData(from cert: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(cert) else { return nil }
        var error: Unmanaged<CFError>?
        if let data = SecKeyCopyExternalRepresentation(key, &error) as Data? {
            return data
        }
        return nil
    }
}
