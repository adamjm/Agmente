import CryptoKit
import Foundation
import Network
import Security

/// TLS settings for one connection (FR-13, FR-14, PLAN 2.6, 2.7).
public struct TransportTLSOptions: @unchecked Sendable {
    /// SHA-256 digests of SubjectPublicKeyInfo DER. If not empty, one certificate in the chain must
    /// match one pin, in addition to normal trust evaluation. Pinning adds to trust; it never replaces it.
    public var spkiPins: [Data]
    /// Extra trust anchors (for a private CA, and for tests). When set, only these anchors are trusted.
    public var trustAnchors: [SecCertificate]
    /// Client certificate for mutual TLS (FR-14).
    public var clientIdentity: SecIdentity?

    public init(spkiPins: [Data] = [], trustAnchors: [SecCertificate] = [], clientIdentity: SecIdentity? = nil) {
        self.spkiPins = spkiPins
        self.trustAnchors = trustAnchors
        self.clientIdentity = clientIdentity
    }

    public var needsCustomVerification: Bool { !spkiPins.isEmpty || !trustAnchors.isEmpty }

    /// Parse pins written as base64 SHA-256 values, one per line or separated by commas or spaces.
    /// Returns nil if any entry is not a 32-byte base64 value.
    public static func parsePins(_ text: String) -> [Data]? {
        let entries = text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("sha256/") ? String($0.dropFirst(7)) : $0 }
            .filter { !$0.isEmpty }
        var pins: [Data] = []
        for entry in entries {
            guard let data = Data(base64Encoded: entry), data.count == 32 else { return nil }
            pins.append(data)
        }
        return pins
    }

    func apply(to options: NWProtocolTLS.Options, queue: DispatchQueue) {
        let sec = options.securityProtocolOptions
        if let identity = clientIdentity, let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        guard needsCustomVerification else { return }
        let pins = spkiPins
        let anchors = trustAnchors
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            complete(TLSVerification.evaluate(trust: trust, pins: pins, anchors: anchors))
        }, queue)
    }
}

/// Trust and pin evaluation, separate from the connection so it can be unit tested.
public enum TLSVerification {
    public static func evaluate(trust: SecTrust, pins: [Data], anchors: [SecCertificate]) -> Bool {
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        guard SecTrustEvaluateWithError(trust, nil) else { return false }
        guard !pins.isEmpty else { return true }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return chain.contains { certificate in
            guard let hash = SPKIPin.sha256(of: certificate) else { return false }
            return pins.contains(hash)
        }
    }
}

/// SHA-256 of a certificate's SubjectPublicKeyInfo DER: the value `openssl ... pkey -pubin -outform der | sha256` gives.
public enum SPKIPin {
    // DER prefixes that turn SecKeyCopyExternalRepresentation output into SubjectPublicKeyInfo.
    private static let rsa2048 = Data([0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00])
    private static let rsa4096 = Data([0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00])
    private static let ecP256 = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])
    private static let ecP384 = Data([0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00])

    /// SubjectPublicKeyInfo DER, or nil for a key type this does not support.
    public static func spkiDER(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let type = attributes[kSecAttrKeyType as String] as? String,
              let bits = attributes[kSecAttrKeySizeInBits as String] as? Int else { return nil }
        let rsa = kSecAttrKeyTypeRSA as String
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String
        let header: Data?
        if type == rsa && bits == 2048 { header = rsa2048 }
        else if type == rsa && bits == 4096 { header = rsa4096 }
        else if type == ec && bits == 256 { header = ecP256 }
        else if type == ec && bits == 384 { header = ecP384 }
        else { header = nil }
        return header.map { $0 + raw }
    }

    public static func sha256(of certificate: SecCertificate) -> Data? {
        spkiDER(of: certificate).map { Data(SHA256.hash(data: $0)) }
    }
}
