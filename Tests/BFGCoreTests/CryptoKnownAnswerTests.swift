import XCTest
@testable import BFGCore

/// The AES and SHA-1 primitives are implemented locally rather than taken from
/// a library, so their correctness is established directly against published
/// test vectors before anything is allowed to depend on them.
///
/// Sources:
///   * FIPS-197 Appendix C.1 — AES-128 single block
///   * NIST SP 800-38A F.1.1 — ECB-AES128.Encrypt
///   * RFC 3174 section 7.3 and FIPS 180-4 examples — SHA-1
final class CryptoKnownAnswerTests: XCTestCase {

    // MARK: - AES-128

    func testAes128FipsVector() throws {
        let key = try Hex.decode("000102030405060708090A0B0C0D0E0F")
        let plain = try Hex.decode("00112233445566778899AABBCCDDEEFF")
        let expected = try Hex.decode("69C4E0D86A7B0430D8CDB78070B4C55A")

        XCTAssertEqual(AES128.encryptBlock(key: key, block: plain), expected)
    }

    func testAes128NistSp80038aEcbVectors() throws {
        let key = try Hex.decode("2B7E151628AED2A6ABF7158809CF4F3C")
        let vectors: [(plain: String, cipher: String)] = [
            ("6BC1BEE22E409F96E93D7E117393172A", "3AD77BB40D7A3660A89ECAF32466EF97"),
            ("AE2D8A571E03AC9C9EB76FAC45AF8E51", "F5D3D58503B9699DE785895A96FDBAAF"),
            ("30C81C46A35CE411E5FBC1191A0A52EF", "43B1CD7F598ECE23881B00E3ED030688"),
            ("F69F2445DF4F9B17AD2B417BE66C3710", "7B0C785E27E8AD3F8223207104725DD4")
        ]

        for vector in vectors {
            let plain = try Hex.decode(vector.plain)
            let expected = try Hex.decode(vector.cipher)
            XCTAssertEqual(Hex.encode(AES128.encryptBlock(key: key, block: plain)),
                           Hex.encode(expected),
                           "plaintext \(vector.plain)")
        }
    }

    // MARK: - SHA-1

    func testSha1Rfc3174Vectors() throws {
        let vectors: [(message: String, digest: String)] = [
            ("abc", "A9993E364706816ABA3E25717850C26C9CD0D89D"),
            ("", "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "84983E441C3BD26EBAAE4AA1F95129E5E54670F1"),
            ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
             + "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
             "A49B2446A02C645BF419F995B67091253A04A259")
        ]

        for vector in vectors {
            let digest = SHA1.hash(Array(vector.message.utf8))
            XCTAssertEqual(Hex.encode(digest), vector.digest, "message \(vector.message)")
        }
    }

    /// Exercises the multi-block padding path: a message crossing the 56-byte
    /// boundary forces an extra zero-padded block.
    func testSha1OneMillionAs() throws {
        let digest = SHA1.hash([UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000))
        XCTAssertEqual(Hex.encode(digest), "34AA973CD4C4DAA4F61EEB2BDBAD27316534016F")
    }
}
