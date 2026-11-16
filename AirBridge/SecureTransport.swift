import Foundation
import Network
import Security
import CryptoKit

/// Separate from the compatibility listener: these ports never accept the
/// historical app-wide key. QR setup is the only way to provision a new key.
enum WieldSecureTransport {
    static let controlPort: UInt16 = 52418
    static let filePort: UInt16 = 52419
    static let serviceType = "_wield-secure._tcp"
    static let fileServiceType = "_wield-files._tcp"

    static func key(secret: Data, purpose: String) -> Data {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(), info: Data("Wield-v2-\(purpose)".utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    static func parameters(keys: [String: Data]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00A8)!)
        // Pre-register every allowed identity. The selection callback is a
        // CLIENT identity-hint callback, not a server key lookup callback.
        for (identity, key) in keys.sorted(by: { $0.key < $1.key }) {
            let k = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let i = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, k as __DispatchData, i as __DispatchData)
        }
        // Revocation must apply to the next handshake, not a cached session.
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let result = NWParameters(tls: tls, tcp: tcp)
        result.allowLocalEndpointReuse = true
        return result
    }

    static func proof(secret: Data, nonce: Data, context: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: nonce + Data(context.utf8), using: SymmetricKey(data: secret)))
    }
    static func verifies(_ proof: Data, secret: Data, nonce: Data, context: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: nonce + Data(context.utf8), using: SymmetricKey(data: secret))
    }
}

struct SecurePairingCode: Codable {
    let v: Int
    let macID: String
    let macName: String
    let qrSecret: String
    let identity: String
    let expires: Date
    var secret: Data? { Data(base64Encoded: qrSecret) }
    var isValid: Bool { v == 2 && !macID.isEmpty && !macName.isEmpty && identity.hasPrefix("qr.") && secret?.count == 32 && expires > Date() }
}

struct RemoteAddress: Codable, Equatable {
    let host: String
    let port: UInt16

    init(_ input: String, defaultPort: UInt16 = WieldSecureTransport.controlPort) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }),
              !text.contains("/"), !text.contains("@"), !text.contains("?"), !text.contains("#"),
              let url = URLComponents(string: "wield://" + text),
              let parsed = url.host, !parsed.isEmpty,
              let port = UInt16(exactly: url.port ?? Int(defaultPort)), port > 0 else {
            throw RemoteError.message("Enter the Mac's Tailscale name or IP address, optionally followed by :port. Use brackets around IPv6 addresses.")
        }
        self.host = parsed.hasPrefix("[") ? String(parsed.dropFirst().dropLast()) : parsed
        self.port = port
    }
    var display: String {
        let address = host.contains(":") ? "[\(host)]" : host
        return port == WieldSecureTransport.controlPort ? address : "\(address):\(port)"
    }
}

enum RemoteError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
