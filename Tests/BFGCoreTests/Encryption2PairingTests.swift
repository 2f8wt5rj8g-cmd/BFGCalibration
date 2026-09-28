import XCTest
@testable import BFGCore

/// Port of `Encryption2PairingTest`.
final class Encryption2PairingTests: XCTestCase {

    func testSetPasswordUsesNameSessionAnd32BytePayload() throws {
        let challenge = try Hex.decode("00112233445566778899AABBCCDDEEFF")
        var password = [UInt8](repeating: 0, count: 32)
        for i in 0..<password.count { password[i] = UInt8(truncatingIfNeeded: i * 7 + 3) }

        let crypto = try Encryption2(bluetoothName: "ABCD1234EFGH56")
        try crypto.establishNameSession(authParam16: challenge)

        var request = try Hex.decode("5AA5203E045C00")
        request.append(contentsOf: password)
        XCTAssertEqual(request.count, 39)

        let encrypted = try crypto.encryptSn(request, counter: 5)
        XCTAssertEqual(45, encrypted.count)

        let decoded = try crypto.decryptSn(encrypted)
        XCTAssertTrue(decoded.macOk)
        XCTAssertEqual(5, decoded.counter)
        XCTAssertEqual(request, decoded.plain)

        let accepted = try crypto.encryptSn(try Hex.decode("5AA500043E5C01"), counter: 7)
        XCTAssertTrue(try crypto.decryptSn(accepted).macOk)
        XCTAssertEqual(try Hex.decode("5AA500043E5C01"), try crypto.decryptSn(accepted).plain)

        try crypto.establishSession(password16: Array(password.prefix(16)), authParam16: challenge)
        var auth = try Hex.decode("5AA50E3E045D00")
        auth.append(contentsOf: Array("ABCD1234EFGH56".utf8))
        XCTAssertEqual(auth.count, 21)

        let roundTripped = try crypto.encryptSn(auth, counter: 8)
        XCTAssertTrue(try crypto.decryptSn(roundTripped).macOk)
    }

    /// Guards the tag comparison against a regression to Swift's `==`, which is
    /// not constant time. A wrong tag must be rejected.
    func testTamperedTagIsRejected() throws {
        let challenge = try Hex.decode("00112233445566778899AABBCCDDEEFF")
        let crypto = try Encryption2(bluetoothName: "ABCD1234EFGH56")
        try crypto.establishNameSession(authParam16: challenge)

        var encrypted = try crypto.encryptSn(try Hex.decode("5AA500043E5C01"), counter: 7)
        encrypted[encrypted.count - 3] ^= 0x01
        XCTAssertFalse(try crypto.decryptSn(encrypted).macOk)
    }
}
