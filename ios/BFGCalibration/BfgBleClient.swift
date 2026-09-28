import Foundation
import CoreBluetooth
import Security
import BFGCore

/// CoreBluetooth port of the Android `BfgBleClient`.
///
/// The protocol layer — frame format, Encryption2, the state sequence, retry
/// and timeout policy — is byte-identical to Android and lives in `BFGCore`,
/// where it is covered by tests that run on Linux. This file supplies only the
/// transport and drives the state machine.
///
/// Credential source differs by design: Android read the official Ninebot
/// app's database (via root or a virtualised container). iOS reads the Keychain
/// entry written by this app's own pairing flow. See `KeychainCredentialStore`.
final class BfgBleClient: NSObject {

    // MARK: - Public surface

    enum Operation {
        case readOnly
        case compareRead
        case writeProfile
        case writeDisVoltage
        case pairAndRead
        case registerScan
    }

    protocol Listener: AnyObject {
        func bleClient(didUpdateStatus status: String)
        func bleClient(didLog line: String)
        func bleClient(didFinish result: Result)
        func bleClient(didFailWith message: String)
    }

    final class Result {
        var serial = ""
        var profileRaw = -1
        var bfgSoc = -1
        var bfgCapacity = -1
        var disBatterySoc = -1
        var disEnergyWh = -1
        var disRemainingCapacity = -1
        var disVrlaVoltage = -1
        var disBfgVersion = -1
        var disDashboardVersion = -1
        var colorDisplayVersion = -1
        var centreControllerVersion = -1
        var disConfigRaw = -1
        var dashboardFirmware = -1
        var meterFirmware = -1
        var pairingConfirmed = false
        var writeCommandSent = false
        var disConfigReadbackVerified = false
        var profileReadbackVerified = false
        var mode: CommunicationModeResolver.Mode = .unsupported
        var writeSupported = false
        var scannedCapacity = -1
        var registerScanReplies = 0

        var meterNominalVoltage: Int {
            profileRaw < 0 ? -1 : BfgProfileCatalog.nominalVoltage(profileRaw)
        }
        var dashboardNominalVoltage: Int {
            let configured = DisVoltageConfig.nominalVoltage(disConfigRaw)
            return configured >= 0 ? configured : DashboardVoltageResolver
                .resolve(energyWh: disEnergyWh, remainingCapacityMah: disRemainingCapacity)
                .nominalVoltage
        }
    }

    // MARK: - State

    private enum State {
        case idle, scanning, connecting, discovering, subscribing
        case waitPreComm, waitPairAuthRetries, waitPairConfirm, waitAuth
        case waitBeforeProfile, waitBeforeSoc, waitBeforeCapacity
        case waitDisDashboardVersion, waitDisEnergyWh, waitDisRemainingCapacity
        case waitDisBattery, waitDisVrlaVoltage, waitDisBfgVersion
        case waitColorDisplayVersion, waitCentreControllerVersion
        case waitDisConfig, waitDisWriteAck, waitDisAfter
        case waitCapacityCompatScan, waitRegisterScan
        case waitWriteAck, waitAfterProfile, waitAfterCapacity
        case done
    }

    private weak var listener: Listener?
    private let operation: Operation
    private let targetProfile: Int
    private let record: DeviceRecord
    private let result = Result()

    private let transport = BleTransport()
    private var crypto: Encryption2?
    private var state: State = .idle
    private var finished = false

    private var password16: [UInt8] = []
    private var pairingPassword32: [UInt8] = []
    private var pairingChallenge16: [UInt8] = []
    private var pairingSerial14: [UInt8] = []
    private var nextCounter = 1

    private var profileVerifyAttempts = 0
    private var capacityVerifyAttempts = 0
    private var disVerifyAttempts = 0
    private var readsCompleted = 0

    private var registerScanModule = 0
    private var registerScanIndex = 0

    private var timeoutWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.bfgtools.calibration.client")

    /// Serial broadcast in the advertised name, learned during the scan.
    private var discoveredSerial = ""
    /// Set when `start()` ran before CoreBluetooth reported its state.
    private var awaitingCentralState = false

    init(record: DeviceRecord, operation: Operation, targetProfile: Int = -1,
         listener: Listener) {
        self.record = record
        self.operation = operation
        self.targetProfile = targetProfile
        self.listener = listener
        super.init()
        transport.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        do {
            if WriteAccessPolicy.isReadOnlySerial(record.effectiveSn), operation != .readOnly,
               operation != .compareRead, operation != .registerScan {
                throw NSError(domain: "bfg", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "该序列号以 N 开头，仅允许读取，不发送任何写入指令。"])
            }

            // Keychain replaces the Android database read. Pairing deliberately
            // ignores any stored key and negotiates a fresh one.
            let stored = operation == .pairAndRead
                ? nil
                : KeychainCredentialStore.shared.load(serial: record.effectiveSn)
            password16 = stored ?? record.passwordCopy()

            // CBCentralManager starts in `.unknown` and only reports
            // `.poweredOn` asynchronously. Treating that initial state as
            // "Bluetooth is off" would fail every first launch, so the scan
            // waits for the delegate callback instead.
            if transport.isPoweredOn {
                beginScan()
            } else {
                awaitingCentralState = true
                status("正在等待蓝牙就绪…")
            }
        } catch {
            fail(describe(error))
        }
    }

    private func beginScan() {
        state = .scanning
        status("正在扫描车辆蓝牙…")
        transport.startScan()
        // 15 s is generous for a foreground scan; the vehicle advertises
        // continuously once awake.
        timeout(.scanning, 15, "未扫描到车辆；请唤醒车辆后重试")
    }

    func cancel() {
        finishNow()
    }

    private func finishNow() {
        finished = true
        timeoutWork?.cancel()
        transport.stopScan()
        transport.disconnect()
    }

    private func finish(_ message: String) {
        guard !finished else { return }
        finishNow()
        state = .done
        status(message)
        listener?.bleClient(didFinish: result)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finishNow()
        listener?.bleClient(didFailWith: message)
    }

    private func status(_ text: String) { listener?.bleClient(didUpdateStatus: text) }
    private func log(_ text: String) { listener?.bleClient(didLog: text) }

    // MARK: - Timeouts

    private func timeout(_ expected: State, _ seconds: Double, _ message: String) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished, self.state == expected else { return }
            self.fail(message)
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func clearTimeout() { timeoutWork?.cancel() }

    // MARK: - Sending

    private func send(_ plain: [UInt8]) {
        guard let crypto else {
            fail("加密会话未建立")
            return
        }
        do {
            let counter = nextCounter
            nextCounter += 1
            let encrypted = try crypto.encryptSn(plain, counter: counter)
            log(NinebotFrame.isFrame(plain, src: 0x3E, dst: 0x04, cmd: 0x5D)
                ? "TX ctr=\(counter) AUTH 身份数据已隐藏"
                : "TX ctr=\(counter) plain=\(Hex.encode(plain))")
            transport.write(Data(encrypted))
        } catch {
            fail("发送失败：\(describe(error))")
        }
    }

    private func sendRaw(_ bytes: [UInt8]) {
        transport.write(Data(bytes))
    }

    // MARK: - Notify handling

    private func handleNotify(_ encrypted: [UInt8]) {
        guard !finished, !encrypted.isEmpty else { return }
        do {
            switch state {
            case .waitPreComm:
                try handlePreComm(encrypted)
            case .waitPairConfirm:
                try handlePairConfirm(encrypted)
            case .waitAuth, .waitBeforeProfile, .waitBeforeSoc, .waitBeforeCapacity,
                 .waitDisDashboardVersion, .waitDisEnergyWh, .waitDisRemainingCapacity,
                 .waitDisBattery, .waitDisVrlaVoltage, .waitDisBfgVersion,
                 .waitColorDisplayVersion, .waitCentreControllerVersion,
                 .waitDisConfig, .waitDisWriteAck, .waitDisAfter,
                 .waitCapacityCompatScan, .waitRegisterScan,
                 .waitWriteAck, .waitAfterProfile, .waitAfterCapacity:
                try handleSessionReply(encrypted)
            default:
                break
            }
        } catch {
            fail(describe(error))
        }
    }

    private func handlePreComm(_ encrypted: [UInt8]) throws {
        guard let crypto else { throw BleError.txNotReady }
        let plain = try crypto.decryptPreComm(encrypted)
        log("PRE_COMM 回复已收到；车辆身份数据已隐藏")

        guard NinebotFrame.isFrame(plain, src: 0x04, dst: 0x3E, cmd: 0x5B) else {
            throw NSError(domain: "bfg", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "PRE_COMM回复格式不符"])
        }
        guard plain.count >= 37 else {
            throw NSError(domain: "bfg", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "PRE_COMM回复过短"])
        }

        let index = Int(plain[6])
        let authParam = Array(plain[7..<23])
        let serialBytes = Array(plain[23..<37])
        let serial = String(decoding: serialBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard !serial.isEmpty else {
            throw NSError(domain: "bfg", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "PRE_COMM未返回车辆SN"])
        }

        result.serial = serial
        clearTimeout()

        if operation == .pairAndRead {
            if !record.effectiveSn.isEmpty,
               record.effectiveSn.caseInsensitiveCompare(serial) != .orderedSame {
                throw NSError(domain: "bfg", code: 5, userInfo: [NSLocalizedDescriptionKey:
                    "车辆序列号与所选设备不一致，已停止配对"])
            }
            pairingChallenge16 = authParam
            pairingSerial14 = serialBytes
            pairingPassword32 = BfgBleClient.randomBytes(32)
            try crypto.establishSession(password16: Array(pairingPassword32.prefix(16)),
                                        authParam16: authParam)
            state = .waitPairAuthRetries
            nextCounter = 2
            status("车辆已识别；正在请求配对…")
            sendPairAuthRetry(0)
            return
        }

        guard index != 0 else {
            throw NSError(domain: "bfg", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "车辆没有已保存BLE密码；请先完成车辆配对"])
        }
        try crypto.establishSession(password16: password16, authParam16: authParam)
        wipePassword()
        state = .waitAuth
        nextCounter = 2
        status("PRE_COMM成功；AUTH…")
        send(try NinebotFrame.authenticate(serial14: serialBytes))
        timeout(.waitAuth, 5, "AUTH无回复")
    }

    /// Mirrors `sendPairAuthRetry`: probe with three AUTH frames, then send
    /// SET_PWD carrying the freshly generated password, then wait for the
    /// rider to press the button on the vehicle.
    private func sendPairAuthRetry(_ attempt: Int) {
        let delay = attempt == 0 ? 0.0 : 0.51
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.finished, self.state == .waitPairAuthRetries else { return }
            guard let crypto = self.crypto else { return }
            do {
                if attempt < 3 {
                    self.send(try NinebotFrame.authenticate(serial14: self.pairingSerial14))
                    self.sendPairAuthRetry(attempt + 1)
                } else {
                    try crypto.establishNameSession(authParam16: self.pairingChallenge16)
                    let plain = NinebotFrame.setPassword(password32: self.pairingPassword32)
                    self.state = .waitPairConfirm
                    self.log("TX ctr=\(self.nextCounter) SET_PWD 内容已隐藏")
                    self.send(plain)
                    self.status("配对请求已发出；请在车辆上按键确认")
                    self.timeout(.waitPairConfirm, 60, "配对确认超时；请唤醒车辆后重试")
                }
            } catch {
                self.fail("配对请求未完成：\(self.describe(error))")
            }
        }
    }

    private func handlePairConfirm(_ encrypted: [UInt8]) throws {
        guard let crypto else { throw BleError.txNotReady }
        let decoded = try crypto.decryptSn(encrypted)
        let plain = decoded.plain
        guard NinebotFrame.isFrame(plain, src: 0x04, dst: 0x3E, cmd: 0x5C), plain.count == 7 else {
            return
        }
        let code = Int(plain[6])
        if code == 0 {
            status("请在车辆上按键确认配对（60 秒内）")
            return
        }
        guard code == 1 else {
            throw NSError(domain: "bfg", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "车辆拒绝了配对请求"])
        }

        clearTimeout()
        let serial = String(decoding: pairingSerial14, as: UTF8.self)
        KeychainCredentialStore.shared.save(serial: serial, password32: pairingPassword32)
        result.pairingConfirmed = true
        try crypto.establishSession(password16: Array(pairingPassword32.prefix(16)),
                                    authParam16: pairingChallenge16)
        status("配对已确认；正在读取…")
        state = .waitBeforeProfile
        send(NinebotFrame.readProfile)
        timeout(.waitBeforeProfile, 5, "读取Profile无回复")
    }

    // MARK: - Reply handling

    private func handleSessionReply(_ encrypted: [UInt8]) throws {
        guard let crypto else { throw BleError.txNotReady }
        let decoded = try crypto.decryptSn(encrypted)
        guard decoded.macOk else {
            throw NSError(domain: "bfg", code: 8, userInfo: [NSLocalizedDescriptionKey:
                "回包校验失败"])
        }
        let plain = decoded.plain

        switch state {
        case .waitAuth:
            guard NinebotFrame.isFrame(plain, src: 0x04, dst: 0x3E, cmd: 0x5D) else { return }
            clearTimeout()
            status("认证完成；开始读取车辆参数…")
            state = .waitBeforeProfile
            send(NinebotFrame.readProfile)
            timeout(.waitBeforeProfile, 5, "读取Profile无回复")

        case .waitBeforeProfile:
            let index = try requireHeader(plain, src: 0x10, dst: 0x3E, cmd: 0x01, len: 8)
            guard index == 0x00, plain.count >= 8 else { return }
            result.profileRaw = Int(plain[7])
            clearTimeout()
            state = .waitBeforeSoc
            send(NinebotFrame.readSoc)
            timeout(.waitBeforeSoc, 5, "读取SOC无回复")

        case .waitBeforeSoc:
            let index = try requireHeader(plain, src: 0x10, dst: 0x3E, cmd: 0x01, len: 8)
            guard index == 0x02, plain.count >= 8 else { return }
            result.bfgSoc = Int(plain[7])
            clearTimeout()
            state = .waitBeforeCapacity
            send(NinebotFrame.readCapacity)
            timeout(.waitBeforeCapacity, 5, "读取容量无回复")

        case .waitBeforeCapacity:
            let index = try requireHeader(plain, src: 0x10, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0x1C, plain.count >= 9 else { return }
            result.bfgCapacity = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            try continueAfterCapacityRead()

        case .waitDisDashboardVersion:
            let index = try requireHeader(plain, src: 0x01, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0x1A, plain.count >= 9 else { return }
            result.dashboardFirmware = NinebotFrame.readLe16(plain, offset: 7)
            result.disDashboardVersion = result.dashboardFirmware
            clearTimeout()
            advanceDisChain()

        case .waitDisEnergyWh:
            let index = try requireHeader(plain, src: 0x01, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0x1E, plain.count >= 9 else { return }
            result.disEnergyWh = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisRemainingCapacity:
            let index = try requireHeader(plain, src: 0x01, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0x44, plain.count >= 9 else { return }
            result.disRemainingCapacity = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisBattery:
            let index = try requireHeader(plain, src: 0x01, dst: 0x3E, cmd: 0x01, len: 8)
            guard index == 0xB5, plain.count >= 8 else { return }
            result.disBatterySoc = Int(plain[7])
            clearTimeout()
            advanceDisChain()

        case .waitDisVrlaVoltage:
            let index = try requireHeader(plain, src: 0x01, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0xB1, plain.count >= 9 else { return }
            result.disVrlaVoltage = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisBfgVersion:
            let index = try requireHeader(plain, src: 0x01, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0x3D, plain.count >= 9 else { return }
            result.meterFirmware = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitColorDisplayVersion:
            let index = try requireHeader(plain, src: 0x01, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0xD1, plain.count >= 9 else { return }
            result.colorDisplayVersion = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitCentreControllerVersion:
            let index = try requireHeader(plain, src: 0x09, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0x02, plain.count >= 9 else { return }
            result.centreControllerVersion = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisConfig:
            let index = try requireHeader(plain, src: 0x01, dst: 0x3E, cmd: 0x01, len: 9)
            guard index == 0x92, plain.count >= 9 else { return }
            result.disConfigRaw = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            resolveAndMaybeWrite()

        default:
            break
        }
    }

    /// Validates the reply header and returns its index byte, so the caller can
    /// confirm it is looking at the reply it asked for.
    @discardableResult
    private func requireHeader(_ plain: [UInt8], src: Int, dst: Int, cmd: Int,
                               len: Int) throws -> Int {
        guard NinebotFrame.isFrame(plain, src: src, dst: dst, cmd: cmd), plain.count >= len else {
            throw NSError(domain: "bfg", code: 9, userInfo: [NSLocalizedDescriptionKey:
                "回包格式不符"])
        }
        return Int(plain[6])
    }

    // MARK: - Read chain and write decision

    private func continueAfterCapacityRead() throws {
        // A read-only run stops here; the remaining registers exist to
        // identify the dashboard firmware before allowing a write.
        if operation == .readOnly || operation == .compareRead {
            finish("读取完成")
            return
        }
        state = .waitDisDashboardVersion
        send(NinebotFrame.readDisDashboardVersion)
        timeout(.waitDisDashboardVersion, 5, "读取仪表版本无回复")
    }

    /// Walks the dashboard identification chain in the order the Android client
    /// uses, then resolves the communication mode.
    private func advanceDisChain() {
        switch state {
        case .waitDisDashboardVersion:
            state = .waitDisEnergyWh
            send(NinebotFrame.readDisEnergyWh)
            timeout(.waitDisEnergyWh, 5, "读取仪表能量无回复")
        case .waitDisEnergyWh:
            state = .waitDisRemainingCapacity
            send(NinebotFrame.readDisRemainingCapacity)
            timeout(.waitDisRemainingCapacity, 5, "读取剩余容量无回复")
        case .waitDisRemainingCapacity:
            state = .waitDisBattery
            send(NinebotFrame.readDisBattery)
            timeout(.waitDisBattery, 5, "读取仪表电量无回复")
        case .waitDisBattery:
            state = .waitDisVrlaVoltage
            send(NinebotFrame.readDisVrlaVoltage)
            timeout(.waitDisVrlaVoltage, 5, "读取仪表电压无回复")
        case .waitDisVrlaVoltage:
            state = .waitDisBfgVersion
            send(NinebotFrame.readDisBfgVersion)
            timeout(.waitDisBfgVersion, 5, "读取计量版本无回复")
        case .waitDisBfgVersion:
            state = .waitColorDisplayVersion
            send(NinebotFrame.readColorDisplayVersion)
            timeout(.waitColorDisplayVersion, 5, "读取彩屏版本无回复")
        case .waitColorDisplayVersion:
            state = .waitCentreControllerVersion
            send(NinebotFrame.readCentreControllerVersion)
            timeout(.waitCentreControllerVersion, 5, "读取中控版本无回复")
        case .waitCentreControllerVersion:
            state = .waitDisConfig
            send(NinebotFrame.readDisConfig)
            timeout(.waitDisConfig, 5, "读取仪表配置无回复")
        default:
            break
        }
    }

    private func resolveAndMaybeWrite() {
        let decision = CommunicationModeResolver.resolve(
            profile: result.profileRaw,
            bfgSoc: result.bfgSoc,
            bfgCapacity: result.bfgCapacity,
            disSoc: result.disBatterySoc,
            disVoltage: result.disVrlaVoltage,
            dashboardVersion: result.dashboardFirmware,
            bfgVersion: result.meterFirmware,
            scannedCapacity: result.scannedCapacity)

        result.mode = decision.mode
        result.writeSupported = decision.writeSupported

        switch operation {
        case .writeProfile:
            guard decision.writeSupported else {
                fail(DashboardWritePolicy.blockedMessage)
                return
            }
            guard !WriteAccessPolicy.isReadOnlySerial(record.effectiveSn) else {
                fail("该序列号以 N 开头，仅允许读取，不发送任何写入指令。")
                return
            }
            sendWriteProfile()
        case .writeDisVoltage:
            guard DashboardWritePolicy.allows(dashboard: result.dashboardFirmware,
                                              colorDisplay: result.colorDisplayVersion,
                                              centre: result.centreControllerVersion,
                                              meter: result.meterFirmware) else {
                fail(DashboardWritePolicy.blockedMessage)
                return
            }
            do {
                let target = try DisVoltageConfig.target(currentRaw: result.disConfigRaw,
                                                         voltage: voltageForProfile(targetProfile))
                result.writeCommandSent = true
                state = .waitDisWriteAck
                send(try disWriteFrame(target))
                timeout(.waitDisWriteAck, 5, "写入确认无回复")
            } catch {
                fail(describe(error))
            }
        default:
            finish("识别完成")
        }
    }

    private func voltageForProfile(_ profile: Int) -> Int {
        let nominal = BfgProfileCatalog.nominalVoltage(profile)
        return nominal > 0 ? nominal : 60
    }

    private func disWriteFrame(_ targetRaw: Int) throws -> [UInt8] {
        // Reuses the tested builder rather than re-deriving the layout here.
        try DisVoltageConfig.writePacket(targetRaw)
    }

    private func sendWriteProfile() {
        writeAckTimeout()
    }

    private func writeAckTimeout() {
        result.writeCommandSent = true
        state = .waitWriteAck
        send(NinebotFrame.writeProfile(targetProfile))
        timeout(.waitWriteAck, 5, "写入确认无回复")
    }

    // MARK: - Helpers

    private func wipePassword() {
        for i in 0..<password16.count { password16[i] = 0 }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        // SecRandomCopyBytes is the platform CSPRNG; the Android code used
        // SecureRandom with the same intent.
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}

// MARK: - Transport delegate

extension BfgBleClient: BleTransportDelegate {
    func bleTransportDidUpdateState(poweredOn: Bool) {
        guard !finished else { return }
        if poweredOn {
            if awaitingCentralState {
                awaitingCentralState = false
                beginScan()
            }
        } else if awaitingCentralState || state == .scanning {
            awaitingCentralState = false
            fail("系统蓝牙未开启")
        }
    }

    func bleTransport(didDiscover peripheral: CBPeripheral, name: String) {
        guard !finished, state == .scanning else { return }
        guard let serial = BfgBleClient.serialFromName(name) else { return }

        if !record.effectiveSn.isEmpty,
           record.effectiveSn.caseInsensitiveCompare(serial) != .orderedSame {
            return
        }

        discoveredSerial = serial
        transport.stopScan()
        clearTimeout()
        state = .connecting
        status("已发现 \(serial)；正在连接…")
        crypto = try? Encryption2(bluetoothName: serial)
        guard crypto != nil else {
            fail("加密初始化失败")
            return
        }
        transport.connect(peripheral)
        timeout(.connecting, 10, "连接超时")
    }

    func bleTransport(didConnect peripheral: CBPeripheral) {
        guard !finished else { return }
        clearTimeout()
        state = .discovering
        status("已连接；正在发现服务…")
        timeout(.discovering, 10, "发现服务超时")
    }

    func bleTransport(didDisconnect error: Error?) {
        guard !finished else { return }
        // The Android client treated a post-write disconnect as a distinct,
        // reportable outcome rather than a generic failure.
        if result.writeCommandSent {
            if result.disConfigReadbackVerified || result.profileReadbackVerified {
                finish("写入指令已发出且已回读确认；随后连接中断。")
            } else {
                fail("写入指令已发送，但连接中断，结果尚未确认；请重新连接读取当前配置。")
            }
            return
        }
        fail("连接已断开" + (error.map { "：\($0.localizedDescription)" } ?? ""))
    }

    func bleTransport(didDiscoverServices error: Error?) {
        guard !finished else { return }
        guard error == nil else {
            fail("发现服务失败：\(describe(error!))")
            return
        }
        clearTimeout()
        state = .subscribing
        status("找到九号BLE通道；开启通知…")
        timeout(.subscribing, 5, "开启通知超时")
    }

    func bleTransport(didUpdateNotificationState error: Error?) {
        guard !finished, state == .subscribing else { return }
        guard error == nil else {
            fail("开启Notify失败")
            return
        }
        do {
            guard let crypto else { throw BleError.txNotReady }
            let encrypted = try crypto.encryptPreComm(NinebotFrame.preComm)
            guard encrypted.count == 13 else {
                throw NSError(domain: "bfg", code: 10, userInfo: [NSLocalizedDescriptionKey:
                    "PRE_COMM加密长度异常"])
            }
            clearTimeout()
            state = .waitPreComm
            status("Notify已开启；发送 PRE_COMM…")
            sendRaw(encrypted)
            timeout(.waitPreComm, 5, "PRE_COMM无回复")
        } catch {
            fail("PRE_COMM失败：\(describe(error))")
        }
    }

    func bleTransport(didReceive data: Data) {
        handleNotify([UInt8](data))
    }

    func bleTransport(didWrite error: Error?) {
        guard error == nil else {
            fail("写入特征失败：\(describe(error!))")
            return
        }
        if state == .waitDisWriteAck || state == .waitWriteAck {
            // The write itself succeeded; the vehicle's reply is what confirms
            // the value, so nothing is finished here.
            log("写入已发送，等待车辆回执")
        }
    }

    /// The vehicle advertises its 14-character serial as the BLE local name.
    /// Android searched the raw advertisement bytes for it; iOS only exposes
    /// the parsed name, so the name itself must be the serial.
    private static func serialFromName(_ name: String) -> String? {
        let pattern = "^[A-Za-z0-9]{14}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              match.range == range else { return nil }
        return name.uppercased()
    }
}
