import Foundation
import BFGCore
import BFGSimulator

/// Runs the real `BfgBleClient` state machine against the simulated vehicle.
///
/// This is the Linux stand-in for "app next to a vehicle": the same client
/// code, the same frames, over a transport that reproduces what a central
/// delivers. Each case below drives one flow end to end and reports whether the
/// client reached the outcome the original protocol implies.

final class Collector: BfgBleClient.Listener {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _finished: BfgBleClient.Result?
    private var _failure: String?
    private var _statuses: [String] = []

    var finished: BfgBleClient.Result? { lock.lock(); defer { lock.unlock() }; return _finished }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return _failure }
    var statuses: [String] { lock.lock(); defer { lock.unlock() }; return _statuses }

    func bleClient(didUpdateStatus status: String) {
        lock.lock(); _statuses.append(status); lock.unlock()
    }

    func bleClient(didLog line: String) { }

    func bleClient(didFinish result: BfgBleClient.Result) {
        lock.lock(); _finished = result; lock.unlock()
        semaphore.signal()
    }

    func bleClient(didFailWith message: String) {
        lock.lock(); _failure = message; lock.unlock()
        semaphore.signal()
    }
}

struct CaseResult {
    let name: String
    let passed: Bool
    let detail: String
}

var results: [CaseResult] = []

@discardableResult
func run(_ name: String, vehicle: VirtualVehicle, operation: BfgBleClient.Operation,
         targetProfile: Int = -1, store: InMemoryCredentialStore,
         record: DeviceRecord? = nil, timeout: TimeInterval = 90,
         verify: (Collector, VirtualVehicle) -> String?) -> CaseResult {
    let link = VirtualLink(vehicle: vehicle)
    let collector = Collector()
    let device = record ?? DeviceRecord(id: -1, mac: "", sn: vehicle.config.serial,
                                        name: vehicle.config.serial, deviceType: "",
                                        password16: [UInt8](repeating: 0, count: 16),
                                        source: "simulator")
    let client = BfgBleClient(record: device, operation: operation,
                              targetProfile: targetProfile,
                              transport: link, credentialStore: store,
                              listener: collector)

    print("\n──── \(name) ────")
    client.start()

    if collector.semaphore.wait(timeout: .now() + timeout) == .timedOut {
        let outcome = CaseResult(name: name, passed: false, detail: "超时未结束")
        results.append(outcome)
        print("  ✗ 超时")
        return outcome
    }

    let outcome: CaseResult
    if let problem = verify(collector, vehicle) {
        outcome = CaseResult(name: name, passed: false, detail: problem)
        print("  ✗ \(problem)")
    } else {
        outcome = CaseResult(name: name, passed: true, detail: "符合预期")
        print("  ✓ 符合预期")
    }
    results.append(outcome)
    return outcome
}

func newStore() -> InMemoryCredentialStore { InMemoryCredentialStore() }

// MARK: - 1. 车辆发现

do {
    let vehicle = VirtualVehicle()
    let store = newStore()
    run("车辆发现（列表）", vehicle: vehicle, operation: .discoverVehicles, store: store) { c, v in
        guard c.failure == nil else { return "失败：\(c.failure!)" }
        guard let r = c.finished else { return "无结果" }
        guard r.discoveredVehicles.count == 1 else {
            return "应发现 1 台，实际 \(r.discoveredVehicles.count)"
        }
        return r.discoveredVehicles[0].serial == v.config.serial ? nil
            : "车架号不符：\(r.discoveredVehicles[0].serial)"
    }
}

// MARK: - 2. 首次配对（车端未存密码）

do {
    var cfg = VirtualVehicle.Config()
    cfg.hasStoredPassword = false
    let virgin = VirtualVehicle(config: cfg)
    let store = newStore()
    run("首次配对 + 读取", vehicle: virgin, operation: .pairAndRead, store: store) { c, v in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.pairingConfirmed else { return "未确认配对" }
        guard store.storedSerials.contains(v.config.serial) else { return "凭据未保存" }
        guard v.config.hasStoredPassword else { return "车端未收到新密码" }
        return nil
    }
}

// MARK: - 3. 常规读取（凭据已存在）

let pairedVehicle = VirtualVehicle()
let pairedStore = newStore()
_ = run("预置配对（为后续用例准备凭据）", vehicle: pairedVehicle,
        operation: .pairAndRead, store: pairedStore) { c, _ in
    c.failure == nil ? nil : "准备失败：\(c.failure!)"
}

/// The negotiated password is the shared secret between client and vehicle;
/// every later vehicle has to hold the same one or AUTH cannot succeed.
let sharedPassword = pairedStore.load(serial: pairedVehicle.config.serial)

func makeVehicle(_ mutate: (inout VirtualVehicle.Config) -> Void = { _ in }) -> VirtualVehicle {
    var cfg = VirtualVehicle.Config()
    cfg.storedPassword32 = sharedPassword
    mutate(&cfg)
    return VirtualVehicle(config: cfg)
}

do {
    let vehicle = makeVehicle()
    run("常规读取（完整 DIS 链 + 模式判定）", vehicle: vehicle,
        operation: .readOnly, store: pairedStore) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        // 原版在只读流程里同样走完整条 DIS 识别链
        guard r.disDashboardVersion != -1 else { return "未读到仪表版本（DIS 链被跳过）" }
        guard r.dashboardFirmware != -1 else { return "未读到仪表固件" }
        guard r.disVrlaVoltage != -1 else { return "未读到 DIS 电压" }
        guard r.colorDisplayVersion != -1, r.centreControllerVersion != -1 else {
            return "彩屏/中控版本缺失"
        }
        guard r.mode != .unsupported else { return "通信模式未判定为可用" }
        guard r.writeSupported else { return "writeSupported 为假，后续写入会被拒" }
        return nil
    }
}

// MARK: - 4. 写入 Profile（车端正常回 ACK）

do {
    let vehicle = makeVehicle()
    run("写入 Profile（ACK 正常）", vehicle: vehicle, operation: .writeProfile,
        targetProfile: 0x21, store: pairedStore) { c, v in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.profileReadbackVerified else { return "未回读确认" }
        guard v.config.profile == 0x21 else { return "车端档位未变为 0x21（实际 0x\(String(v.config.profile, radix: 16))）" }
        return nil
    }
}

// MARK: - 5. 写入 Profile（ACK 丢失，必须靠回读完成）

do {
    let vehicle = makeVehicle { $0.sendWriteAck = false }
    run("写入 Profile（ACK 丢失 → 必须靠回读成功）", vehicle: vehicle,
        operation: .writeProfile, targetProfile: 0x21, store: pairedStore) { c, v in
        if let f = c.failure { return "失败：\(f)（ACK 丢失不应导致失败）" }
        guard let r = c.finished else { return "无结果" }
        guard r.profileReadbackVerified else { return "未回读确认" }
        guard v.config.profile == 0x21 else { return "车端档位未生效" }
        return nil
    }
}

// MARK: - 6. 写入 Profile（车端延迟 2 次回读才生效）

do {
    let vehicle = makeVehicle { $0.writeAppliesAfterReads = 2 }
    run("写入 Profile（延迟生效 → 重试后成功）", vehicle: vehicle,
        operation: .writeProfile, targetProfile: 0x21, store: pairedStore) { c, v in
        if let f = c.failure { return "失败：\(f)（应在重试上限内成功）" }
        guard let r = c.finished else { return "无结果" }
        guard r.verificationRetried else { return "未发生重试，与预期不符" }
        guard r.profileReadbackVerified, v.config.profile == 0x21 else { return "最终未生效" }
        return nil
    }
}

// MARK: - 7. 写入 Profile（车端始终不生效 → 4 次后失败）

do {
    let vehicle = makeVehicle { $0.writeAppliesAfterReads = 99 }
    run("写入 Profile（始终不生效 → 必须失败）", vehicle: vehicle,
        operation: .writeProfile, targetProfile: 0x21, store: pairedStore) { c, _ in
        guard c.failure != nil else { return "应失败但成功了（会掩盖真实写入失败）" }
        return nil
    }
}

// MARK: - 8. N 开头序列号 → 只读

do {
    let vehicle = makeVehicle { $0.serial = "NINEB000000001" }
    let store = newStore()
    run("N 开头序列号 → 拒绝写入", vehicle: vehicle, operation: .writeProfile,
        targetProfile: 0x21, store: store) { c, _ in
        guard let f = c.failure, f.contains("N 开头") else {
            return "应因只读序列号被拒，实际：\(c.failure ?? "成功")"
        }
        return nil
    }
}

// MARK: - 9. 固件不在白名单 → 拒绝写入

do {
    // The dashboard allowlist gates a *dashboard* write only; a meter-profile
    // write is gated by writeSupported instead. 0x0999 is outside the list.
    let vehicle = makeVehicle { $0.dashboardVersion = 0x0999 }
    run("仪表固件不在白名单 → 拒绝仪表盘写入", vehicle: vehicle,
        operation: .writeDisVoltage, targetProfile: 72, store: pairedStore) { c, _ in
        guard let f = c.failure else { return "应被拒但成功了" }
        guard f.contains("仪表盘") else { return "拒绝原因不符：\(f)" }
        return nil
    }
}

// MARK: - 10. 容量兼容扫描（非白名单固件 + 常规容量异常）

do {
    // An unrecognised meter version and an implausible capacity together are
    // what make the client run the compatibility scan.
    let vehicle = makeVehicle {
        $0.meterVersion = 0x0100
        $0.capacityMah = 12345
        $0.compatRegisters = [0x0E: 26000, 0x0F: 26000, 0x1A: 26000, 0x1C: 26000, 0x1E: 26000]
    }
    run("容量兼容扫描 → 判定为兼容模式", vehicle: vehicle, operation: .readOnly,
        store: pairedStore) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.mode == .capacityScanCompat else {
            return "应判定为兼容模式，实际 \(CommunicationModeResolver.label(r.mode))"
        }
        guard r.scannedCapacity == 26000 else { return "扫描选值不符：\(r.scannedCapacity)" }
        return nil
    }
}

// MARK: - 11. 容量扫描寄存器全部无响应 → 不致命

do {
    // The compatibility registers go silent, but 0x1C still answers: the scan
    // must tolerate silence rather than treat it as fatal. (Silencing 0x1C
    // itself would instead fail the earlier capacity read, which is also what
    // the original does, so it is not a scan-tolerance case.)
    let vehicle = makeVehicle {
        $0.meterVersion = 0x0100
        $0.silentRegisters = [VirtualVehicle.Register(0x10, 0x0E),
                              VirtualVehicle.Register(0x10, 0x0F),
                              VirtualVehicle.Register(0x10, 0x1A),
                              VirtualVehicle.Register(0x10, 0x1E)]
    }
    run("容量兼容扫描（部分寄存器无响应）→ 不致命", vehicle: vehicle,
        operation: .readOnly, store: pairedStore, timeout: 180) { c, _ in
        guard let r = c.finished else { return "应完成而非崩溃：\(c.failure ?? "无结果")" }
        guard r.mode == .capacityScanCompat else {
            return "应回退到 0x1C 并判为兼容模式，实际 \(CommunicationModeResolver.label(r.mode))"
        }
        guard r.scannedCapacity == 26000 else { return "回退取值不符：\(r.scannedCapacity)" }
        return nil
    }
}

// MARK: - 12. 寄存器只读扫描

do {
    let vehicle = makeVehicle()
    run("寄存器只读扫描（仪表盘）", vehicle: vehicle, operation: .registerScan,
        targetProfile: RegisterReadPlan.dashboard, store: pairedStore, timeout: 180) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.registerScanReplies > 0 else { return "未收到任何应答" }
        guard r.registerScanTimeouts + r.registerScanReplies > 0 else { return "计数未回填" }
        return nil
    }
}

// MARK: - 汇总

print("\n" + String(repeating: "═", count: 62))
print("结果汇总")
print(String(repeating: "═", count: 62))
for r in results {
    print(String(format: "  %@ %-38@ %@", r.passed ? "✓" : "✗", r.name as NSString, r.detail))
}
let failed = results.filter { !$0.passed }.count
print(String(repeating: "─", count: 62))
print("  \(results.count - failed)/\(results.count) 通过")
if failed > 0 {
    print("  失败 \(failed) 项")
    exit(1)
}
