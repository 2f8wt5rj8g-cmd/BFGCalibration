/// AES-128 single-block encryption, FIPS-197.
///
/// Only forward block encryption is needed: the Ninebot protocol builds CTR and
/// CBC-MAC style constructions out of it and never decrypts a block directly.
///
/// This is deliberately dependency-free so the identical bytes are produced on
/// Linux (where the port is verified) and on iOS. `AES128KnownAnswerTests`
/// pins it to the official FIPS-197 Appendix C vectors, which is what makes it
/// safe to swap in CommonCrypto on iOS behind the same tests.
enum AES128 {
    /// One AES-128 block encryption. `key` must be 16 bytes, `block` 16 bytes.
    static func encryptBlock(key: [UInt8], block: [UInt8]) -> [UInt8] {
        precondition(key.count == 16, "AES-128 key must be 16 bytes")
        precondition(block.count == 16, "AES block must be 16 bytes")

        let roundKeys = expandKey(key)
        var state = block

        addRoundKey(&state, roundKeys, round: 0)
        for round in 1..<10 {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, roundKeys, round: round)
        }
        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, roundKeys, round: 10)
        return state
    }

    // MARK: - Key schedule

    private static let rcon: [UInt8] = [
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36
    ]

    private static func expandKey(_ key: [UInt8]) -> [UInt8] {
        var expanded = [UInt8](repeating: 0, count: 176)
        for i in 0..<16 { expanded[i] = key[i] }

        var generated = 16
        var round = 0
        var temp = [UInt8](repeating: 0, count: 4)

        while generated < 176 {
            for i in 0..<4 { temp[i] = expanded[generated - 4 + i] }

            if generated % 16 == 0 {
                // RotWord
                let first = temp[0]
                temp[0] = temp[1]
                temp[1] = temp[2]
                temp[2] = temp[3]
                temp[3] = first
                // SubWord
                for i in 0..<4 { temp[i] = sBox[Int(temp[i])] }
                // Rcon
                temp[0] ^= rcon[round]
                round += 1
            }

            for i in 0..<4 {
                expanded[generated] = expanded[generated - 16] ^ temp[i]
                generated += 1
            }
        }
        return expanded
    }

    // MARK: - Round transforms

    private static func addRoundKey(_ state: inout [UInt8], _ roundKeys: [UInt8], round: Int) {
        let offset = round * 16
        for i in 0..<16 { state[i] ^= roundKeys[offset + i] }
    }

    private static func subBytes(_ state: inout [UInt8]) {
        for i in 0..<16 { state[i] = sBox[Int(state[i])] }
    }

    /// The state is column-major: byte index `4*column + row`.
    private static func shiftRows(_ state: inout [UInt8]) {
        var out = state
        for row in 0..<4 {
            for column in 0..<4 {
                out[4 * column + row] = state[4 * ((column + row) % 4) + row]
            }
        }
        state = out
    }

    private static func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let base = 4 * column
            let a0 = state[base]
            let a1 = state[base + 1]
            let a2 = state[base + 2]
            let a3 = state[base + 3]

            state[base] = mul2(a0) ^ mul3(a1) ^ a2 ^ a3
            state[base + 1] = a0 ^ mul2(a1) ^ mul3(a2) ^ a3
            state[base + 2] = a0 ^ a1 ^ mul2(a2) ^ mul3(a3)
            state[base + 3] = mul3(a0) ^ a1 ^ a2 ^ mul2(a3)
        }
    }

    /// Multiplication by x in GF(2^8) modulo the AES polynomial 0x11B.
    ///
    /// The reduction must be masked back to eight bits: `0x100 ^ 0x1B` is 0x11B,
    /// which does not fit in a byte.
    private static func mul2(_ value: UInt8) -> UInt8 {
        let shifted = UInt16(value) << 1
        if shifted & 0x100 != 0 {
            return UInt8((shifted ^ 0x1B) & 0xFF)
        }
        return UInt8(shifted)
    }

    private static func mul3(_ value: UInt8) -> UInt8 {
        mul2(value) ^ value
    }

    // MARK: - S-box (FIPS-197 Figure 7)

    private static let sBox: [UInt8] = [
        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16
    ]
}
