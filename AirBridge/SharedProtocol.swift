import Foundation
import CryptoKit
import Network

/// A Codable enum representing a value that can be String, Int, or Double.
/// Encodes and decodes using a single value container.
public enum CodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
            return
        }
        if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
            return
        }
        if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
            return
        }
        throw DecodingError.typeMismatch(
            CodableValue.self,
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "Value cannot be decoded into String, Int or Double"))
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        }
    }
}

/// Represents a control packet to be sent or received by AirPad and AirBridge devices.
/// Contains deviceID, timestamp, type, payload, and HMAC signature.
public struct ControlPacket: Codable, Equatable {
    /// Unique identifier of the device sending or receiving the packet.
    public let deviceID: String
    /// Timestamp of the packet in seconds since the Unix epoch.
    public let timestamp: Double
    /// Type or category of the packet.
    public let type: String
    /// Payload dictionary with String keys and CodableValue values.
    public let payload: [String: CodableValue]
    /// Hex-encoded HMAC-SHA256 signature of the canonical JSON data.
    public let hmac: String
    
    public init(deviceID: String, timestamp: Double, type: String, payload: [String: CodableValue], hmac: String) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
        self.hmac = hmac
    }
    
    /// A canonical representation of a control packet excluding the HMAC field.
    /// Used for computing and verifying the HMAC signature.
    public struct Canonical: Codable {
        public let deviceID: String
        public let timestamp: Double
        public let type: String
        public let payload: [String: CodableValue]
        
        public init(deviceID: String, timestamp: Double, type: String, payload: [String: CodableValue]) {
            self.deviceID = deviceID
            self.timestamp = timestamp
            self.type = type
            self.payload = payload
        }
    }
    
    /// Returns the JSON-encoded canonical data (excluding `hmac`) with sorted keys, suitable for HMAC.
    /// Throws encoding errors if encoding fails.
    public func canonicalDataForHMAC() throws -> Data {
        let canonical = Canonical(deviceID: deviceID, timestamp: timestamp, type: type, payload: payload)
        let encoder = canonicalJSONEncoder()
        return try encoder.encode(canonical)
    }
}

/// Utility to encode and sign ControlPackets.
public struct PacketEncoder {
    /// Constructs a ControlPacket with the given parameters, computes the HMAC-SHA256 over the canonical JSON,
    /// sets the hex-encoded HMAC string, and returns the JSON-encoded Data with sorted keys.
    ///
    /// - Parameters:
    ///   - deviceID: Unique device identifier.
    ///   - type: Packet type.
    ///   - payload: Payload dictionary.
    ///   - secret: Secret key for HMAC computation.
    ///   - timestamp: Packet timestamp.
    /// - Returns: JSON Data of the signed control packet.
    /// - Throws: Encoding or HMAC computation errors.
    public static func signAndEncode(deviceID: String,
                                     type: String,
                                     payload: [String: CodableValue],
                                     secret: Data,
                                     timestamp: Double) throws -> Data {
        let packet = try signPacket(deviceID: deviceID, type: type, payload: payload, secret: secret, timestamp: timestamp)
        let encoder = canonicalJSONEncoder()
        return try encoder.encode(packet)
    }
    
    /// Constructs a ControlPacket with the given parameters, computes the HMAC-SHA256 over the canonical JSON,
    /// sets the hex-encoded HMAC string, and returns the signed ControlPacket instance.
    ///
    /// - Parameters:
    ///   - deviceID: Unique device identifier.
    ///   - type: Packet type.
    ///   - payload: Payload dictionary.
    ///   - secret: Secret key for HMAC computation.
    ///   - timestamp: Packet timestamp.
    /// - Returns: Signed ControlPacket instance.
    /// - Throws: Encoding or HMAC computation errors.
    public static func signPacket(deviceID: String,
                                  type: String,
                                  payload: [String: CodableValue],
                                  secret: Data,
                                  timestamp: Double) throws -> ControlPacket {
        let canonical = ControlPacket.Canonical(deviceID: deviceID, timestamp: timestamp, type: type, payload: payload)
        let encoder = canonicalJSONEncoder()
        let canonicalData = try encoder.encode(canonical)
        let hmacData = HMACUtility.hmacSHA256(key: secret, data: canonicalData)
        let hmacHex = hmacData.hexString()
        return ControlPacket(deviceID: deviceID, timestamp: timestamp, type: type, payload: payload, hmac: hmacHex)
    }
}

/// Utility to validate and verify ControlPackets.
public struct PacketValidator {
    /// Validates the given JSON data by decoding it as a ControlPacket, verifying structure,
    /// validating the HMAC signature, and checking timestamp freshness.
    ///
    /// - Parameters:
    ///   - jsonData: JSON data representing a ControlPacket.
    ///   - secret: Secret key used to verify the HMAC.
    ///   - maxSkewSeconds: Maximum allowed clock skew in seconds.
    /// - Returns: A valid ControlPacket if all checks pass.
    /// - Throws: `PacketError` describing the validation failure.
    public static func validate(jsonData: Data, secret: Data, maxSkewSeconds: TimeInterval) throws -> ControlPacket {
        let decoder = JSONDecoder()
        guard let packet = try? decoder.decode(ControlPacket.self, from: jsonData) else {
            throw PacketError.decodingFailed
        }
        
        try validateStructure(packet)
        
        // Verify HMAC
        let canonicalData = try packet.canonicalDataForHMAC()
        let expectedHMACData = HMACUtility.hmacSHA256(key: secret, data: canonicalData)
        guard let receivedHMACData = Data(hexString: packet.hmac) else {
            throw PacketError.invalidStructure("HMAC is not a valid hex string")
        }
        guard expectedHMACData == receivedHMACData else {
            throw PacketError.invalidHMAC
        }
        
        // Validate timestamp freshness
        let now = Date().timeIntervalSince1970
        let skew = abs(now - packet.timestamp)
        if skew > maxSkewSeconds {
            throw PacketError.staleTimestamp(allowedSkew: maxSkewSeconds, actualSkew: skew)
        }
        
        return packet
    }
    
    /// Validates the structural integrity of the ControlPacket.
    ///
    /// - Parameter packet: ControlPacket to validate.
    /// - Throws: `PacketError.invalidStructure` if any structural check fails.
    public static func validateStructure(_ packet: ControlPacket) throws {
        if packet.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PacketError.invalidStructure("deviceID is empty")
        }
        if packet.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PacketError.invalidStructure("type is empty")
        }
        if packet.timestamp <= 0 || packet.timestamp > 4102444800 { // 2100-01-01 GMT approx
            throw PacketError.invalidStructure("timestamp is out of reasonable bounds")
        }
        for key in packet.payload.keys {
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PacketError.invalidStructure("payload contains empty key")
            }
        }
        if packet.hmac.count != 64 || !packet.hmac.allSatisfy({ $0.isHexDigit }) {
            throw PacketError.invalidStructure("hmac must be 64 hex characters")
        }
    }
}

/// Errors thrown during packet validation and processing.
public enum PacketError: Error, LocalizedError {
    /// The packet structure is invalid with a descriptive message.
    case invalidStructure(String)
    /// The HMAC signature verification failed.
    case invalidHMAC
    /// The packet timestamp is outside the allowed clock skew.
    case staleTimestamp(allowedSkew: TimeInterval, actualSkew: TimeInterval)
    /// Failed to encode packet data.
    case encodingFailed
    /// Failed to decode packet data.
    case decodingFailed
    
    public var errorDescription: String? {
        switch self {
        case .invalidStructure(let msg):
            return "Invalid structure: \(msg)"
        case .invalidHMAC:
            return "Invalid HMAC signature"
        case .staleTimestamp(let allowed, let actual):
            return "Stale timestamp: allowed skew \(allowed)s, actual skew \(actual)s"
        case .encodingFailed:
            return "Encoding failed"
        case .decodingFailed:
            return "Decoding failed"
        }
    }
}

/// Utility providing SHA-256 hashing.
public struct HashUtility {
    /// Computes SHA-256 hash of the given data.
    ///
    /// - Parameter data: Data to hash.
    /// - Returns: SHA-256 digest data.
    public static func sha256(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }
}

/// Utility providing HMAC-SHA256 computation.
public struct HMACUtility {
    /// Computes HMAC-SHA256 of the given data using the provided key.
    ///
    /// - Parameters:
    ///   - key: Secret key as Data.
    ///   - data: Data to sign.
    /// - Returns: HMAC-SHA256 digest data.
    public static func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(authenticationCode)
    }
}

/// Extension for Data to provide hex string conversion and initialization.
public extension Data {
    /// Returns a hex-encoded string of the data.
    ///
    /// - Parameter lowercase: Whether the hex string should be lowercase. Default is true.
    /// - Returns: Hex string representation.
    func hexString(lowercase: Bool = true) -> String {
        let hex = self.map { String(format: lowercase ? "%02x" : "%02X", $0) }.joined()
        return hex
    }
    
    /// Initializes Data from a hex string.
    ///
    /// - Parameter hexString: Hex string representation of data. Case-insensitive, must have even length.
    init?(hexString: String) {
        let len = hexString.count
        if len % 2 != 0 {
            return nil
        }
        var data = Data(capacity: len / 2)
        var index = hexString.startIndex
        for _ in 0..<(len / 2) {
            let nextIndex = hexString.index(index, offsetBy: 2)
            let byteString = hexString[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

/// Returns a JSONEncoder configured to encode with sorted keys and without escaping slashes.
/// This ensures canonical JSON serialization for consistent HMAC computation.
public func canonicalJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

/// Builds the secure (TLS-PSK) transport shared by AirPad and AirBridge.
///
/// We use an external TLS pre-shared key rather than certificates: it gives
/// confidentiality *and* mutual authentication (both peers must hold the same
/// key) in one step, with no certificate provisioning. The PSK `identity` is how
/// the server will look up the correct per-device key in Stage 2; in Stage 1 a
/// single hardcoded key is used on both sides purely to validate the channel.
public enum AirSecureChannel {
    /// STAGE 1 ONLY — temporary shared key/identity used to prove the encrypted
    /// channel end-to-end. Stage 2 replaces this with per-device keys exchanged
    /// out-of-band (QR / pairing code), so this constant goes away entirely.
    public static let stage1Identity = "airbridge-stage1"
    public static let stage1PSK: Data = Data("airbridge-stage1-temporary-psk-please-replace".utf8)

    /// Construct `NWParameters` for a TLS-PSK channel. Works for both the client
    /// (connection) and the server (listener) — PSK setup is symmetric.
    ///
    /// External PSK requires TLS 1.2 with a PSK ciphersuite; TLS 1.3 in
    /// Network.framework only supports resumption PSKs, not external ones.
    public static func makePSKParameters(psk: Data, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec,
                                                pskData as __DispatchData,
                                                identityData as __DispatchData)

        // TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8) — use the raw value so this
        // compiles regardless of SDK enum-case naming differences.
        if let suite = tls_ciphersuite_t(rawValue: 0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        }

        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        return params
    }
}
