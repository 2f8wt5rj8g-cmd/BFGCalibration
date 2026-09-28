/// Port of `com.bfgtools.calibration.core.Hex`.
///
/// Java `byte` is signed and required `& 0xFF` masks throughout the original.
/// Swift `UInt8` is unsigned, so every one of those masks is now implicit.
public enum Hex {
    public enum Error: Swift.Error, Equatable {
        case oddLength
        case invalidCharacter(Character)
    }

    private static let digits: [Character] = Array("0123456789ABCDEF")

    /// Mirrors `Hex.decode`. Accepts surrounding whitespace, requires an even
    /// number of digits, and is case-insensitive.
    public static func decode(_ string: String) throws -> [UInt8] {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        guard characters.count.isMultiple(of: 2) else { throw Error.oddLength }

        var out = [UInt8]()
        out.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            let high = try nibble(characters[index])
            let low = try nibble(characters[index + 1])
            out.append((high << 4) | low)
            index += 2
        }
        return out
    }

    private static func nibble(_ character: Character) throws -> UInt8 {
        switch character {
        case "0"..."9": return UInt8(character.asciiValue! - 0x30)
        case "A"..."F": return UInt8(character.asciiValue! - 0x37)
        case "a"..."f": return UInt8(character.asciiValue! - 0x57)
        default: throw Error.invalidCharacter(character)
        }
    }

    public static func encode(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }

    /// The Java constructor of `Encryption2` decodes a hard-coded constant at
    /// class-init time, where a checked error cannot propagate. This companion
    /// keeps that same shape for compile-time literals.
    static func literal(_ string: String) -> [UInt8] {
        do {
            return try decode(string)
        } catch {
            preconditionFailure("malformed hex literal: \(string)")
        }
    }
}
