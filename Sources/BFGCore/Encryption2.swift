import Foundation

/// Port of `com.bfgtools.calibration.core.Encryption2`.
///
/// Ninebot Encryption2 helper. Password/session keys are held in memory only
/// and are never logged, matching the original contract.
///
/// Two Java-specific behaviours needed deliberate care here:
///   * `byte` is signed in Java. Every read in the original applied `& 0xFF`;
///     with `UInt8` those masks are structural and cannot be forgotten.
///   * `MessageDigest.isEqual` is constant-time. Swift's `==` on arrays is not,
///     so `constantTimeEquals` is used for the authentication tag instead.
public final class Encryption2 {
    public static let dataBasic: [UInt8] = Hex.literal("97CFB802844143DE56002B3B34780A5D")

    public struct Decoded {
        public let plain: [UInt8]
        public let counter: Int
        public let macOk: Bool
    }

    private let initialKey: [UInt8]
    private let nameKeyMaterial: [UInt8]
    private var sessionKey: [UInt8]?
    private var authParam: [UInt8]?

    public enum Failure: Swift.Error, Equatable {
        case invalidFrame
        case shortFrame
        case counterOutOfRange
        case sessionNotEstablished
        case invalidKeyLength
    }

    public init(bluetoothName: String?) throws {
        let name = Array((bluetoothName ?? "").utf8)
        self.initialKey = try Encryption2.deriveKey(name, Encryption2.dataBasic)
        let tail = name.count <= 16 ? name : Array(name[(name.count - 16)...])
        self.nameKeyMaterial = Encryption2.pad16(tail)
    }

    public static func deriveKey(_ a: [UInt8], _ b: [UInt8]) throws -> [UInt8] {
        var material = pad16(a)
        material.append(contentsOf: pad16(b))
        return Array(SHA1.hash(material).prefix(16))
    }

    public func establishSession(password16: [UInt8], authParam16: [UInt8]) throws {
        guard password16.count == 16, authParam16.count == 16 else {
            throw Failure.invalidKeyLength
        }
        self.authParam = authParam16
        self.sessionKey = try Encryption2.deriveKey(password16, authParam16)
    }

    public func establishNameSession(authParam16: [UInt8]) throws {
        try establishSession(password16: nameKeyMaterial, authParam16: authParam16)
    }

    // MARK: - Pre-command (fixed key stream)

    public func encryptPreComm(_ plain: [UInt8]) throws -> [UInt8] {
        guard plain.count >= 7, plain[0] == 0x5A, plain[1] == 0xA5 else {
            throw Failure.invalidFrame
        }
        let body = Array(plain[3...])
        let keystream = AES128.encryptBlock(key: initialKey, block: Encryption2.dataBasic)

        var encryptedBody = [UInt8](repeating: 0, count: body.count)
        for i in 0..<body.count { encryptedBody[i] = body[i] ^ keystream[i & 15] }

        var sum = 0
        for byte in body { sum = (sum + Int(byte)) & 0xFFFF }
        let checksum = (~sum) & 0xFFFF

        var out = Array(plain[0..<3])
        out.append(contentsOf: encryptedBody)
        out.append(0)
        out.append(0)
        out.append(UInt8(checksum & 0xFF))
        out.append(UInt8((checksum >> 8) & 0xFF))
        out.append(0)
        out.append(0)
        return out
    }

    public func decryptPreComm(_ encrypted: [UInt8]) throws -> [UInt8] {
        guard encrypted.count >= 9 else { throw Failure.shortFrame }
        let body = Array(encrypted[3..<(encrypted.count - 6)])
        let keystream = AES128.encryptBlock(key: initialKey, block: Encryption2.dataBasic)

        var plain = Array(encrypted[0..<3])
        for i in 0..<body.count { plain.append(body[i] ^ keystream[i & 15]) }
        return plain
    }

    // MARK: - Session frames

    public func encryptSn(_ plain: [UInt8], counter: Int) throws -> [UInt8] {
        try ensureSession()
        guard counter > 0, counter <= 0xFFFF else { throw Failure.counterOutOfRange }

        let body = Array(plain[3...])
        let cipherBody = try cryptCtr(body, counter: counter)
        let tag = try encryptedTag(plain: plain, counter: counter)

        var out = Array(plain[0..<3])
        out.append(contentsOf: cipherBody)
        out.append(contentsOf: tag)
        out.append(UInt8((counter >> 8) & 0xFF))
        out.append(UInt8(counter & 0xFF))
        return out
    }

    public func decryptSn(_ encrypted: [UInt8]) throws -> Decoded {
        try ensureSession()
        guard encrypted.count >= 9 else { throw Failure.shortFrame }

        let counter = (Int(encrypted[encrypted.count - 2]) << 8) | Int(encrypted[encrypted.count - 1])
        let cipherBody = Array(encrypted[3..<(encrypted.count - 6)])
        let plainBody = try cryptCtr(cipherBody, counter: counter)

        var plain = Array(encrypted[0..<3])
        plain.append(contentsOf: plainBody)

        let expected = try encryptedTag(plain: plain, counter: counter)
        let got = Array(encrypted[(encrypted.count - 6)..<(encrypted.count - 2)])
        return Decoded(plain: plain, counter: counter, macOk: Encryption2.constantTimeEquals(expected, got))
    }

    // MARK: - Constructions

    private func cryptCtr(_ input: [UInt8], counter: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count)
        let nonce = self.nonce(counter)

        var blockIndex = 1
        var offset = 0
        while offset < input.count {
            var a = [UInt8](repeating: 0, count: 16)
            a[0] = 0x01
            for i in 0..<13 { a[1 + i] = nonce[i] }
            a[14] = 0
            a[15] = UInt8(blockIndex & 0xFF)

            let keystream = AES128.encryptBlock(key: try sessionKeyOrThrow(), block: a)
            let count = min(16, input.count - offset)
            for i in 0..<count { out[offset + i] = input[offset + i] ^ keystream[i] }

            offset += 16
            blockIndex += 1
        }
        return out
    }

    /// CBC-MAC style tag truncated to 4 bytes, then masked with the first four
    /// bytes of the A0 counter block.
    private func encryptedTag(plain: [UInt8], counter: Int) throws -> [UInt8] {
        let key = try sessionKeyOrThrow()
        let body = Array(plain[3...])
        let nonce = self.nonce(counter)

        var b0 = [UInt8](repeating: 0, count: 16)
        b0[0] = 0x59
        for i in 0..<13 { b0[1 + i] = nonce[i] }
        b0[14] = 0
        b0[15] = UInt8(body.count & 0xFF)
        var x = AES128.encryptBlock(key: key, block: b0)

        var aad = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(3, plain.count) { aad[i] = plain[i] }
        x = AES128.encryptBlock(key: key, block: Encryption2.xor16(x, aad))

        var offset = 0
        while offset < body.count {
            var block = [UInt8](repeating: 0, count: 16)
            let count = min(16, body.count - offset)
            for i in 0..<count { block[i] = body[offset + i] }
            x = AES128.encryptBlock(key: key, block: Encryption2.xor16(x, block))
            offset += 16
        }

        var tag = Array(x.prefix(4))
        var a0 = [UInt8](repeating: 0, count: 16)
        a0[0] = 0x01
        for i in 0..<13 { a0[1 + i] = nonce[i] }
        a0[14] = 0
        a0[15] = 0
        let s0 = AES128.encryptBlock(key: key, block: a0)
        for i in 0..<4 { tag[i] ^= s0[i] }
        return tag
    }

    private func nonce(_ counter: Int) -> [UInt8] {
        var n = [UInt8](repeating: 0, count: 13)
        n[0] = 0
        n[1] = 0
        n[2] = UInt8((counter >> 8) & 0xFF)
        n[3] = UInt8(counter & 0xFF)
        for i in 0..<8 { n[4 + i] = authParam![i] }
        n[12] = 0
        return n
    }

    // MARK: - Helpers

    private func sessionKeyOrThrow() throws -> [UInt8] {
        guard let sessionKey else { throw Failure.sessionNotEstablished }
        return sessionKey
    }

    private func ensureSession() throws {
        guard sessionKey != nil, authParam != nil else { throw Failure.sessionNotEstablished }
    }

    private static func xor16(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { out[i] = a[i] ^ b[i] }
        return out
    }

    private static func pad16(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(16, input.count) { out[i] = input[i] }
        return out
    }

    /// Replaces `MessageDigest.isEqual`. Comparing tag bytes with `==` would
    /// leak the position of the first mismatch through timing.
    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}
