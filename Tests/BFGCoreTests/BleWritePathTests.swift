import XCTest
@testable import BFGCore
import BFGSimulator

/// The write type is chosen from what the vehicle's TX characteristic actually
/// advertises.
///
/// Android picked `WRITE_TYPE_NO_RESPONSE` whenever the characteristic offered
/// it. CoreBluetooth is stricter: a write whose type the characteristic does not
/// declare is refused by the OS instead of being downgraded, so hard-coding the
/// type is the difference between a frame arriving and nothing happening on the
/// vehicle at all.
final class BleWritePolicyTests: XCTestCase {
    func testPrefersWriteWithoutResponseWhenBothAreOffered() {
        // The original's exact rule: NO_RESPONSE wins when it is available.
        XCTAssertEqual(.withoutResponse,
                       BleWritePolicy.writeType(supportsWrite: true,
                                                supportsWriteWithoutResponse: true))
    }

    func testFallsBackToAcknowledgedWriteWhenThatIsAllThereIs() {
        XCTAssertEqual(.withResponse,
                       BleWritePolicy.writeType(supportsWrite: true,
                                                supportsWriteWithoutResponse: false))
    }

    func testACharacteristicThatCannotBeWrittenIsReported() {
        // Neither property: CoreBluetooth would refuse every frame, which is
        // worth saying out loud rather than discovering as silence.
        XCTAssertNil(BleWritePolicy.writeType(supportsWrite: false,
                                              supportsWriteWithoutResponse: false))
    }
}

/// Records what the client reported so a test can assert on the outcome.
private final class Recorder: BfgBleClient.Listener {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _failure: String?
    private var _finished: BfgBleClient.Result?

    var failure: String? { lock.lock(); defer { lock.unlock() }; return _failure }
    var finished: BfgBleClient.Result? { lock.lock(); defer { lock.unlock() }; return _finished }

    func bleClient(didUpdateStatus status: String) { }
    func bleClient(didLog line: String) { }

    func bleClient(didFinish result: BfgBleClient.Result) {
        lock.lock(); _finished = result; lock.unlock()
        done.signal()
    }

    func bleClient(didFailWith message: String) {
        lock.lock(); _failure = message; lock.unlock()
        done.signal()
    }
}

/// The Keychain entry this app's own pairing writes is the only credential
/// source on iOS; Android could fall back to the Ninebot database. An operation
/// that authenticates without one cannot succeed, and saying so up front is the
/// difference between "先配对" and a rider hunting a Bluetooth fault on the
/// vehicle because the run died at AUTH.
final class CredentialPreconditionTests: XCTestCase {

    private func makeClient(vehicle: VirtualVehicle,
                            operation: BfgBleClient.Operation,
                            store: InMemoryCredentialStore) -> (BfgBleClient, VirtualLink, Recorder) {
        let link = VirtualLink(vehicle: vehicle)
        let recorder = Recorder()
        let record = DeviceRecord(id: -1, mac: "", sn: vehicle.config.serial,
                                  name: vehicle.config.serial, deviceType: "",
                                  password16: [UInt8](repeating: 0, count: 16),
                                  source: "simulator")
        let client = BfgBleClient(record: record, operation: operation,
                                  transport: link, credentialStore: store,
                                  listener: recorder)
        return (client, link, recorder)
    }

    func testReadWithoutAStoredCredentialFailsBeforeTouchingTheRadio() {
        let vehicle = VirtualVehicle()
        let store = InMemoryCredentialStore()
        let (client, link, recorder) = makeClient(vehicle: vehicle,
                                                  operation: .readOnly, store: store)

        client.start()
        XCTAssertEqual(.success, recorder.done.wait(timeout: .now() + 5),
                       "未配对时应当立即结束，而不是等超时")

        guard let failure = recorder.failure else {
            return XCTFail("未配对却继续执行了读取")
        }
        XCTAssertTrue(failure.contains("配对"), "提示应当指出需要先配对：\(failure)")
        XCTAssertEqual(0, link.connectCalls, "未配对时不应该连接车辆")
        XCTAssertTrue(link.writes.isEmpty, "未配对时不应该发出任何指令")
    }

    func testPairingIsNotBlockedByThePrecondition() {
        var config = VirtualVehicle.Config()
        config.hasStoredPassword = false
        let vehicle = VirtualVehicle(config: config)
        let store = InMemoryCredentialStore()
        let (client, link, recorder) = makeClient(vehicle: vehicle,
                                                  operation: .pairAndRead, store: store)

        client.start()
        _ = recorder.done.wait(timeout: .now() + 20)

        // Pairing negotiates its own password, so an empty store must not stop
        // it: the client has to reach the vehicle.
        XCTAssertGreaterThan(link.connectCalls, 0, "配对被前置校验误伤")
        XCTAssertFalse(link.writes.isEmpty, "配对应当已经发出 PRE_COMM")
    }

    func testVehicleDiscoveryDoesNotNeedACredential() {
        let vehicle = VirtualVehicle()
        let store = InMemoryCredentialStore()
        let (client, _, recorder) = makeClient(vehicle: vehicle,
                                              operation: .discoverVehicles, store: store)

        client.start()
        _ = recorder.done.wait(timeout: .now() + 15)

        // Discovery is how a rider gets to the pairing screen at all.
        XCTAssertFalse(recorder.failure?.contains("凭据") ?? false,
                       "车辆发现不应该要求先配对：\(recorder.failure ?? "")")
    }
}
