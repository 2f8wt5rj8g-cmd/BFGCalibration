import Foundation
import BFGCore

/// A vehicle-side implementation of the Ninebot Encryption2 protocol.
///
/// **Where this comes from.** The original project is an Android *client*; the
/// vehicle side is not in the source. Every rule here is therefore derived from
/// what that client sends and what it accepts back — frame layouts, the
/// `isReadAckFrom(src, index, dataLen)` assertions, the reply the client needs
/// at each step. It is deliberately **not** derived from this port, so that
/// running the port against it can disagree with it.
///
/// **What that buys, and what it does not.** This validates that the client is
/// self-consistent with the protocol as the original understands it, and that a
/// port of it does not silently drift. It cannot prove the real vehicle behaves
/// this way: the original source never observed the vehicle directly.
public final class VirtualVehicle {

    /// Behaviour knobs. Defaults describe a healthy, fully-featured vehicle;
    /// the others exist so the abnormal paths can be exercised.
    public struct Config {
        /// Advertised name, and the identity the client matches on. The
        /// original requires `[A-Z0-9]{14}`, and refuses writes to any serial
        /// starting with "N" — so a default here must avoid that prefix.
        public var serial = "BFGTEST0000001"
        /// Whether the vehicle reports an already-stored BLE password. The
        /// client refuses a read/write run when this is false.
        public var hasStoredPassword = true
        /// 32-byte password the vehicle holds; replaces the stub below when set.
        public var storedPassword32: [UInt8]?

        /// 0x51 is index 5 at 60V, which the profile table puts at 26000 —
        /// profile and capacity have to agree or the read resolves as a
        /// compatibility case instead of the normal path.
        public var profile = 0x51
        public var soc = 76
        public var capacityMah = 26000
        public var dashboardVersion = 0x0259
        public var colorDisplayVersion = 0x0155
        public var centreVersion = 0x05CA
        public var meterVersion = 0x0429
        public var energyWh = 960
        public var remainingCapacityMah = 15000
        /// DIS battery register. The original reads this as a little-endian
        /// 16-bit value, so the default is a plausible raw value rather than a
        /// bare percentage.
        public var batteryRaw = 0x004C
        public var vrlaVoltageRaw = 5820
        public var disConfigRaw = 0xC2
        /// Compatibility-scan registers 0x0E/0x0F/0x1A/0x1E.
        public var compatRegisters: [Int: Int] = [0x0E: 26000, 0x0F: 26000, 0x1A: 26000, 0x1E: 26000]

        /// Send the `CMD 0x05` write acknowledgement. The client must complete
        /// the write even when this is false, by falling back to a read-back.
        public var sendWriteAck = true
        /// How many read-backs pass before a written value becomes visible.
        /// Models a vehicle that persists lazily, exercising the retry loop.
        public var writeAppliesAfterReads = 0
        /// Registers that never answer, as `(dst, index)`.
        public var silentRegisters: Set<Register> = []
        /// Refuse `SET_PWD` (reply status other than 0/1).
        public var rejectPairing = false
        /// Emit `SET_PWD` status 0 ("press the button") this many times first.
        public var pairConfirmPendingReplies = 0
        /// Drop the connection after this many replies. -1 disables.
        public var disconnectAfterReplies = -1
        /// Accept `SET_PWD` but then refuse the follow-up AUTH.
        public var rejectPostPairAuth = false

        public init() { }
    }

    public struct Register: Hashable {
        public let dst: Int
        public let index: Int
        public init(_ dst: Int, _ index: Int) {
            self.dst = dst
            self.index = index
        }
    }

    public private(set) var config: Config

    /// Frames the vehicle produced, in order, for inspection by tests.
    public private(set) var sentFrames: [[UInt8]] = []
    /// Every plaintext request the vehicle accepted, for inspection.
    public private(set) var receivedRequests: [[UInt8]] = []

    private var authParam: [UInt8] = []
    private var nameSession: Encryption2?
    private var passwordSession: Encryption2?
    private var storedPassword32: [UInt8]
    private var nextCounter = 1
    private var repliesSent = 0
    private var pendingConfirmReplies = 0
    private var readBacksSinceWrite = 0
    private var stagedProfile: Int?
    private var stagedDisConfig: Int?

    /// Set when the vehicle decides the link should drop.
    public private(set) var wantsDisconnect = false

    public init(config: Config = Config()) {
        self.config = config
        let stub = (0..<32).map { UInt8($0) }
        self.storedPassword32 = config.storedPassword32 ?? stub
    }

    // MARK: - Link

    /// Builds the vehicle's view of a fresh connection. `authParam` is minted
    /// per connection, as the original's PRE_COMM reply carries it each time.
    public func connectionOpened() {
        authParam = SecureRandom.bytes(16)
        nameSession = try? Encryption2(bluetoothName: config.serial)
        // SET_PWD arrives under the name-derived session, because the client
        // has to send it before the vehicle knows the new password.
        try? nameSession?.establishNameSession(authParam16: authParam)
        passwordSession = try? Encryption2(bluetoothName: config.serial)
        try? passwordSession?.establishSession(password16: Array(storedPassword32.prefix(16)),
                                               authParam16: authParam)
        nextCounter = 1
        repliesSent = 0
        pendingConfirmReplies = config.pairConfirmPendingReplies
        readBacksSinceWrite = 0
        stagedProfile = nil
        stagedDisConfig = nil
        wantsDisconnect = false
    }

    /// The name the vehicle advertises, which doubles as its identity: the
    /// original matches `[A-Z0-9]{14}` against the advertised name because no
    /// platform-independent device address is available.
    public var advertisedName: String { config.serial }

    /// Tears down the per-connection state.
    public func connectionClosed() {
        wantsDisconnect = false
        nameSession = nil
        passwordSession = nil
    }

    /// Feeds one framed write from the client and returns the frames to send
    /// back. An empty array means the vehicle stayed silent.
    public func receive(_ line: [UInt8]) -> [[UInt8]] {
        guard let nameSession, let passwordSession else { return [] }

        // PRE_COMM is the only frame on the initial-key layer, and the only one
        // that carries no counter.
        if let plain = try? nameSession.decryptPreComm(line), isPreComm(plain) {
            receivedRequests.append(plain)
            return replyPreComm(nameSession: nameSession)
        }

        // The client sends three AUTH probes under the *new* password before
        // SET_PWD, which the vehicle cannot authenticate yet. They are ignored;
        // so is anything else that fails its tag check.
        let opened = openSession(line, name: nameSession, password: passwordSession, session: passwordSession)
        guard let (plain, counter, _) = opened else { return [] }
        _ = counter
        receivedRequests.append(plain)

        // A name-session frame is only ever SET_PWD.
        if plain.count >= 7, plain[5] == 0x5C {
            return handleSetPassword(plain)
        }
        return handleSessionFrame(plain)
    }

    private func openSession(_ line: [UInt8], name: Encryption2, password: Encryption2,
                             session: Encryption2) -> ([UInt8], Int, Bool)? {
        // A frame authenticated by neither session is noise (the pairing probes).
        if let decoded = try? password.decryptSn(line), decoded.macOk {
            return (decoded.plain, decoded.counter, true)
        }
        if let decoded = try? name.decryptSn(line), decoded.macOk {
            return (decoded.plain, decoded.counter, true)
        }
        return nil
    }

    private func isPreComm(_ plain: [UInt8]) -> Bool {
        // The client's request is phone -> BLE board, so SRC=0x3E, DST=0x04.
        // (The reply runs the other way; only the request arrives here.)
        plain.count >= 7 && plain[0] == 0x5A && plain[1] == 0xA5
            && plain[3] == 0x3E && plain[4] == 0x04 && plain[5] == 0x5B
    }

    // MARK: - Pairing

    private func replyPreComm(nameSession: Encryption2) -> [[UInt8]] {
        var plain = [UInt8](repeating: 0, count: 37)
        plain[0] = 0x5A
        plain[1] = 0xA5
        plain[2] = 0x1E                     // 30 bytes of data: 16 + 14
        plain[3] = 0x04
        plain[4] = 0x3E
        plain[5] = 0x5B
        // The client reads this as "does the vehicle already hold a password".
        plain[6] = config.hasStoredPassword ? 0x01 : 0x00
        plain.replaceSubrange(7..<23, with: authParam)
        let serialBytes = Array(config.serial.utf8.prefix(14))
        plain.replaceSubrange(23..<37, with: serialBytes)
        // The reply must decrypt under the same name-derived key the request used.
        let encrypted = (try? nameSession.encryptPreComm(plain)) ?? plain
        sentFrames.append(encrypted)
        return [encrypted]
    }

    private func handleSetPassword(_ plain: [UInt8]) -> [[UInt8]] {
        guard plain.count >= 39 else { return [] }
        let newPassword = Array(plain[7..<39])

        if config.rejectPairing {
            return [encode([0x5A, 0xA5, 0x00, 0x04, 0x3E, 0x5C, 0x02], nameSession: true)]
        }
        // Status 0 means "waiting for the rider to press the button"; the client
        // keeps waiting without resetting its own timeout.
        if pendingConfirmReplies > 0 {
            pendingConfirmReplies -= 1
            return [encode([0x5A, 0xA5, 0x00, 0x04, 0x3E, 0x5C, 0x00], nameSession: true)]
        }

        storedPassword32 = newPassword
        config.hasStoredPassword = true
        // From here the vehicle answers the new credential's session.
        passwordSession = try? Encryption2(bluetoothName: config.serial)
        try? passwordSession?.establishSession(password16: Array(newPassword.prefix(16)),
                                               authParam16: authParam)
        return [encode([0x5A, 0xA5, 0x00, 0x04, 0x3E, 0x5C, 0x01], nameSession: true)]
    }

    // MARK: - Session frames

    private func handleSessionFrame(_ plain: [UInt8]) -> [[UInt8]] {
        guard plain.count >= 7 else { return [] }
        let dst = Int(plain[4])
        let cmd = plain[5]

        switch cmd {
        case 0x5D:
            // AUTH: the SN must match the vehicle's own.
            let sn = plain.count >= 21 ? Array(plain[7..<21]) : []
            let expected = Array(config.serial.utf8.prefix(14))
            guard sn == expected, !config.rejectPostPairAuth else {
                return [encode([0x5A, 0xA5, 0x00, 0x04, 0x3E, 0x5D, 0x00])]
            }
            return [encode([0x5A, 0xA5, 0x00, 0x04, 0x3E, 0x5D, 0x01])]

        case 0x01:
            let index = Int(plain[6])
            guard !config.silentRegisters.contains(Register(dst, index)) else { return [] }
            guard let data = readValue(dst: dst, index: index) else { return [] }
            return [encode([0x5A, 0xA5, UInt8(data.count), UInt8(dst), 0x3E, 0x04, UInt8(index)] + data)]

        case 0x02:
            return handleWrite(dst: dst, index: Int(plain[6]), data: Array(plain.dropFirst(7)))

        default:
            return []
        }
    }

    private func handleWrite(dst: Int, index: Int, data: [UInt8]) -> [[UInt8]] {
        var replies: [[UInt8]] = []

        if dst == 0x10 && index == 0x00 && data.count >= 1 {
            let target = Int(data[0])
            if config.writeAppliesAfterReads == 0 {
                config.profile = target
            } else {
                stagedProfile = target
                readBacksSinceWrite = 0
            }
        } else if dst == 0x01 && index == 0x92 && data.count >= 2 {
            let target = NinebotFrame.readLe16([0x00, 0x00] + data, offset: 2)
            if config.writeAppliesAfterReads == 0 {
                config.disConfigRaw = target
            } else {
                stagedDisConfig = target
                readBacksSinceWrite = 0
            }
            // Keep the nominal voltage in step, so a read-back reports the write.
        }

        // CMD 0x02 answers with CMD 0x05, carrying the writing module as source.
        if config.sendWriteAck {
            replies.append(encode([0x5A, 0xA5, 0x00, UInt8(dst), 0x3E, 0x05, 0x00]))
        }
        return replies
    }

    // MARK: - Reads

    private func readValue(dst: Int, index: Int) -> [UInt8]? {
        // A lazily-persisting vehicle reveals the staged value only after the
        // configured number of read-backs, which is what drives the retry loop.
        if stagedProfile != nil || stagedDisConfig != nil {
            readBacksSinceWrite += 1
            if readBacksSinceWrite >= config.writeAppliesAfterReads {
                if let staged = stagedProfile {
                    config.profile = staged
                    stagedProfile = nil
                }
                if let staged = stagedDisConfig {
                    config.disConfigRaw = staged
                    stagedDisConfig = nil
                }
            }
        }

        switch (dst, index) {
        case (0x10, 0x00): return [UInt8(config.profile & 0xFF)]
        case (0x10, 0x02): return [UInt8(config.soc & 0xFF)]
        case (0x10, 0x1C): return le16(config.capacityMah)
        case (0x01, 0x1A): return le16(config.dashboardVersion)
        case (0x01, 0x1E): return le16(config.energyWh)
        case (0x01, 0x44): return le16(config.remainingCapacityMah)
        case (0x01, 0xB5): return le16(config.batteryRaw)
        case (0x01, 0xB1): return le16(config.vrlaVoltageRaw)
        case (0x01, 0x3D): return le16(config.meterVersion)
        case (0x01, 0xD1): return le16(config.colorDisplayVersion)
        case (0x09, 0x02): return le16(config.centreVersion)
        case (0x01, 0x92): return le16(config.disConfigRaw)
        case (0x10, let reg) where config.compatRegisters[reg] != nil:
            return le16(config.compatRegisters[reg] ?? 0)
        // A real vehicle answers across its whole register space; silence is
        // the exception, and is modelled by `silentRegisters`. Answering the
        // rest keeps a 256-address sweep from taking three minutes.
        case (0x01, _), (0x10, _), (0x04, _), (0x09, _):
            return le16(0)
        default:
            return nil
        }
    }

    private func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    // MARK: - Framing

    private func encode(_ plain: [UInt8], nameSession: Bool = false) -> [UInt8] {
        repliesSent += 1
        if config.disconnectAfterReplies >= 0, repliesSent > config.disconnectAfterReplies {
            wantsDisconnect = true
        }
        let session = nameSession ? self.nameSession : passwordSession
        let counter = nextCounter
        nextCounter = nextCounter >= 0xFFFF ? 1 : nextCounter + 1
        let encrypted = (try? session?.encryptSn(plain, counter: counter)) ?? plain
        sentFrames.append(encrypted)
        return encrypted
    }
}
