//
//  BLECoverageTransmitterTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import XCTest
@testable import xdrip

final class BLECoverageTransmitterTests: XCTestCase {
    private let m5StackCharacteristic = "6D810E9F-0983-4030-BDA7-C7C9A6A19C1C"
    private let medtrumCharacteristic = "669A9141-0008-968F-E311-6050405558B3"
    private let medtrumKeys = ["medtrumTouchCareNano.sensorStartDate", "medtrumTouchCareNano.lastDeliveredCounter",
                               UserDefaults.Key.activeSensorStartDate.rawValue, UserDefaults.Key.appInForeGround.rawValue,
                               UserDefaults.Key.timeStampOfLastHeartBeat.rawValue]
    private var savedDefaults = [String: Any]()
    private var recorder: BLECoverageRecorder!
    private var cgmRecorder: DexcomCoverageRecorder!
    private let peripheralObject = NSObject()

    override func setUp() {
        super.setUp()
        for key in medtrumKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.appInForeGround = true
        recorder = BLECoverageRecorder()
        cgmRecorder = DexcomCoverageRecorder()
    }

    override func tearDown() {
        for key in medtrumKeys {
            UserDefaults.standard.set(savedDefaults[key], forKey: key)
        }
        recorder = nil
        cgmRecorder = nil
        super.tearDown()
    }

    // MARK: - M5Stack

    func testM5StackPasswordPacketsCompleteConnectionSetup() throws {
        let transmitter = makeM5Stack()
        XCTAssertFalse(transmitter.isReadyToReceiveData)
        let packets = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: "abcdefghijklmnopqrstuvwxyz", maxBytesInOneBLEPacket: 20, opCode: 0x0E))
        XCTAssertEqual(packets.count, 2)
        receive(transmitter, m5StackCharacteristic, packets[0])
        drainMain()
        XCTAssertTrue(recorder.passwords.isEmpty)
        receive(transmitter, m5StackCharacteristic, packets[1])
        drainMain()
        XCTAssertTrue(transmitter.isReadyToReceiveData)
        XCTAssertEqual(recorder.passwords, ["abcdefghijklmnopqrstuvwxyz"])
        XCTAssertGreaterThanOrEqual(recorder.readyCount, 1)
        transmitter.prepareForRelease()
        XCTAssertFalse(transmitter.isReadyToReceiveData)
    }

    func testM5StackAuthenticationResults() {
        let transmitter = makeM5Stack()
        receive(transmitter, m5StackCharacteristic, Data([0x0C]))
        drainMain()
        XCTAssertEqual(recorder.authentications, [false])
        XCTAssertFalse(transmitter.isReadyToReceiveData)
        receive(transmitter, m5StackCharacteristic, Data([0x0B]))
        drainMain()
        XCTAssertEqual(recorder.authentications, [false, true])
        XCTAssertTrue(transmitter.isReadyToReceiveData)
    }

    func testM5StackStatusMessagesReachDelegates() {
        let transmitter = makeM5Stack()
        for value in [Data([0x0D]), Data([0x0F]), Data([0x16]), Data([0x20, 77]), Data([0x20]), Data([0x21]), Data([0x11]), Data([0x99]), Data()] {
            receive(transmitter, m5StackCharacteristic, value)
        }
        drainMain()
        XCTAssertEqual(recorder.passwordMissingCount, 1)
        XCTAssertEqual(recorder.resetRequiredCount, 1)
        XCTAssertEqual(recorder.allParametersCount, 1)
        XCTAssertEqual(recorder.batteryLevels, [77])
        XCTAssertEqual(recorder.heartBeats, 1)
        XCTAssertTrue(recorder.authentications.isEmpty)
    }

    func testM5StackWritesFailWhileDisconnected() {
        let transmitter = makeM5Stack(type: .M5StickCType)
        XCTAssertEqual(transmitter.bluetoothPeripheralType, .M5StickCType)
        XCTAssertFalse(transmitter.writeRotation(rotation: 4))
        XCTAssertFalse(transmitter.writeRotation(rotation: -1))
        XCTAssertFalse(transmitter.writeRotation(rotation: 1))
        XCTAssertFalse(transmitter.writeBrightness(brightness: 50))
        XCTAssertFalse(transmitter.writeBloodGlucoseUnit(isMgDl: true))
        XCTAssertFalse(transmitter.readBatteryLevel())
        XCTAssertFalse(transmitter.powerOff())
        XCTAssertFalse(transmitter.writeTextColor(textColor: .red))
        XCTAssertFalse(transmitter.writeBackGroundColor(backGroundColor: .black))
    }

    func testM5StackColorWireValues() {
        XCTAssertEqual(M5StackColor.red.data, Data([0xF8, 0x00]))
        XCTAssertEqual(M5StackColor.green.data, Data([0x07, 0xE0]))
        XCTAssertEqual(M5StackColor.white.data, Data([0xFF, 0xFF]))
        XCTAssertEqual(M5StackColor.yellow.data, Data([0xFF, 0xE0]))
        XCTAssertEqual(M5StackColor.black.data, Data([0x00, 0x00]))
        XCTAssertEqual(M5StackColor(forUInt16: 0x07E0), .green)
        XCTAssertNil(M5StackColor(forUInt16: 0x1234))
    }

    // MARK: - Medtrum

    func testMedtrumConfiguration() {
        let transmitter = makeMedtrum()
        XCTAssertEqual(transmitter.cgmTransmitterType(), .medtrumTouchCareNano)
        XCTAssertEqual(transmitter.maxSensorAgeInDays(), 14)
        XCTAssertFalse(transmitter.needsSensorStartTime())
        XCTAssertTrue(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.nonWebOOPAllowed())
        XCTAssertEqual(transmitter.getCBUUID_Service(), "669A9001-0008-968F-E311-6050405558B3")
        XCTAssertEqual(transmitter.getCBUUID_Receive(), medtrumCharacteristic)
    }

    func testMedtrumDecodesGlucoseUsingCalibrationFactor() throws {
        let transmitter = makeMedtrum()
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 360, raw: 1200, history: [0, 0, 0], factor: 10_000))
        drainMain()
        let reading = try XCTUnwrap(cgmRecorder.glucoseBatches.first?.first)
        XCTAssertEqual(reading.glucoseLevelRaw, 120, accuracy: 0.0001)
        XCTAssertEqual(cgmRecorder.sensorAges, [43_200])
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "medtrumTouchCareNano.lastDeliveredCounter"), 360)
        let start = try XCTUnwrap(UserDefaults.standard.object(forKey: "medtrumTouchCareNano.sensorStartDate") as? Date)
        XCTAssertEqual(Date().timeIntervalSince(start), 43_200, accuracy: 10)
    }

    func testMedtrumSkipsDuplicatesAndBackfillsMissedCycles() throws {
        let transmitter = makeMedtrum()
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 100, raw: 1000, history: [0, 0, 0], factor: 10_000))
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 100, raw: 1000, history: [0, 0, 0], factor: 10_000))
        drainMain()
        XCTAssertEqual(cgmRecorder.glucoseBatches.count, 1)
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 103, raw: 1300, history: [1200, 100, 1000], factor: 10_000))
        drainMain()
        let batch = try XCTUnwrap(cgmRecorder.glucoseBatches.last)
        XCTAssertEqual(batch.map(\.glucoseLevelRaw), [130, 120])
        XCTAssertNil(batch[0].backfilledAt)
        XCTAssertNotNil(batch[1].backfilledAt)
        XCTAssertEqual(batch[0].timeStamp.timeIntervalSince(batch[1].timeStamp), 120, accuracy: 0.001)
    }

    func testMedtrumBackfillIsLimitedToThreeReadings() throws {
        let transmitter = makeMedtrum()
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 10, raw: 1000, history: [0, 0, 0], factor: 10_000))
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 20, raw: 1000, history: [1100, 1200, 1300], factor: 10_000))
        drainMain()
        XCTAssertEqual(cgmRecorder.glucoseBatches.last?.map(\.glucoseLevelRaw), [100, 110, 120, 130])
    }

    func testMedtrumRejectsInvalidPackets() {
        let transmitter = makeMedtrum()
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 1, raw: 100, history: [0, 0, 0], factor: 10_000))
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 2, raw: 5000, history: [0, 0, 0], factor: 10_000))
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 3, raw: 1000, history: [0, 0, 0], factor: 0))
        var badMarker = medtrumPacket(counter: 4, raw: 1000, history: [0, 0, 0], factor: 10_000)
        badMarker[1] = 0x03
        receive(transmitter, medtrumCharacteristic, badMarker)
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 5, raw: 1000, history: [0, 0, 0], factor: 10_000).dropLast())
        receive(transmitter, "669A9142-0008-968F-E311-6050405558B3", medtrumPacket(counter: 6, raw: 1000, history: [0, 0, 0], factor: 10_000))
        let characteristic = BLECoverageCharacteristic(uuid: medtrumCharacteristic, value: medtrumPacket(counter: 7, raw: 1000, history: [0, 0, 0], factor: 10_000))
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateValueFor: characteristic, error: NSError(domain: "test", code: 1))
        drainMain()
        XCTAssertTrue(cgmRecorder.glucoseBatches.isEmpty)
    }

    func testMedtrumRestoredInstanceDoesNotRedeliverPersistedCounter() {
        receive(makeMedtrum(), medtrumCharacteristic, medtrumPacket(counter: 50, raw: 1000, history: [0, 0, 0], factor: 10_000))
        drainMain()
        receive(makeMedtrum(), medtrumCharacteristic, medtrumPacket(counter: 50, raw: 1000, history: [0, 0, 0], factor: 10_000))
        drainMain()
        XCTAssertEqual(cgmRecorder.glucoseBatches.count, 1)
        receive(makeMedtrum(), medtrumCharacteristic, medtrumPacket(counter: 52, raw: 1050, history: [1020, 0, 0], factor: 10_000))
        drainMain()
        XCTAssertEqual(cgmRecorder.glucoseBatches.last?.map(\.glucoseLevelRaw), [105, 102])
    }

    func testMedtrumReportsNewSensorWhenInferredStartMoves() throws {
        UserDefaults.standard.activeSensorStartDate = Date().addingTimeInterval(-10 * 86_400)
        let transmitter = makeMedtrum()
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 30, raw: 1000, history: [0, 0, 0], factor: 10_000))
        drainMain()
        let start = try XCTUnwrap(cgmRecorder.newSensorDates.first ?? nil)
        XCTAssertEqual(Date().timeIntervalSince(start), 3600, accuracy: 10)
        UserDefaults.standard.activeSensorStartDate = start
        receive(transmitter, medtrumCharacteristic, medtrumPacket(counter: 31, raw: 1000, history: [0, 0, 0], factor: 10_000))
        drainMain()
        XCTAssertEqual(cgmRecorder.newSensorDates.count, 1)
    }

    func testMedtrumNotificationStateChangesAreHandled() {
        let transmitter = makeMedtrum()
        let notifying = BLECoverageCharacteristic(uuid: medtrumCharacteristic, value: nil, notifying: true)
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateNotificationStateFor: notifying, error: nil)
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateNotificationStateFor: notifying, error: NSError(domain: "test", code: 1))
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateNotificationStateFor: BLECoverageCharacteristic(uuid: m5StackCharacteristic, value: nil), error: nil)
        XCTAssertTrue(transmitter.shouldTimeoutStalledConnectionSetup())
        drainMain()
        XCTAssertTrue(cgmRecorder.glucoseBatches.isEmpty)
    }

    // MARK: - Heartbeat transmitters

    func testG7HeartbeatFiresOncePerWindowAndStoresTimestamp() {
        let transmitter = DexcomG7HeartbeatBluetoothTransmitter(address: nil, name: nil, transmitterID: "DXCMHB", bluetoothTransmitterDelegate: recorder)
        addTeardownBlock { transmitter.prepareForRelease() }
        receive(transmitter, "F8083535-849E-531C-C594-30F1F86A4EA5", Data([0x01]))
        receive(transmitter, "F8083535-849E-531C-C594-30F1F86A4EA5", Data([0x01]))
        let stored = UserDefaults.standard.timeStampOfLastHeartBeat
        XCTAssertEqual(stored?.timeIntervalSinceNow ?? -100, 0, accuracy: 5)
        waitForHeartBeats(1)
        XCTAssertEqual(recorder.heartBeats, 1)
        XCTAssertNil(transmitter.batteryLevel)
    }

    func testG7HeartbeatPublishesStandardBatteryLevel() {
        let transmitter = DexcomG7HeartbeatBluetoothTransmitter(address: UUID().uuidString, name: nil, transmitterID: "DXCMHB", bluetoothTransmitterDelegate: recorder)
        addTeardownBlock { transmitter.prepareForRelease() }
        let service = CBMutableService(type: StandardBluetoothBatteryLevel.serviceUUID, primary: true)
        let battery = BLECoverageCharacteristic(uuid: "2A19", value: Data([64]), service: service)
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateValueFor: battery, error: nil)
        let invalid = BLECoverageCharacteristic(uuid: "2A19", value: Data([200]), service: service)
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateValueFor: invalid, error: nil)
        drainMain()
        XCTAssertEqual(transmitter.batteryLevel, 64)
        XCTAssertEqual(recorder.batteryLevels, [64])
        transmitter.updateBatteryLevel()
        transmitter.prepareForRelease()
        XCTAssertNil(transmitter.batteryLevel)
    }

    func testG7HeartbeatIgnoresBatteryServiceWithoutReadableLevel() {
        let transmitter = DexcomG7HeartbeatBluetoothTransmitter(address: nil, name: nil, transmitterID: "DXCMHB", bluetoothTransmitterDelegate: recorder)
        addTeardownBlock { transmitter.prepareForRelease() }
        let service = CBMutableService(type: StandardBluetoothBatteryLevel.serviceUUID, primary: true)
        service.characteristics = [CBMutableCharacteristic(type: CBUUID(string: "2A19"), properties: [.notify], value: nil, permissions: [])]
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didDiscoverCharacteristicsFor: service, error: nil)
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didDiscoverCharacteristicsFor: service, error: NSError(domain: "test", code: 1))
        transmitter.updateBatteryLevel()
        drainMain()
        XCTAssertNil(transmitter.batteryLevel)
    }

    func testOmniPodHeartbeatFiresForEveryValue() {
        let transmitter = OmniPodHeartBeatTransmitter(address: UUID().uuidString, name: nil, bluetoothTransmitterDelegate: recorder)
        addTeardownBlock { transmitter.prepareForRelease() }
        receive(transmitter, "1A7E2442-E3ED-4464-8B7E-751E03D0DC5F", Data([0x01]))
        receive(transmitter, "1A7E2442-E3ED-4464-8B7E-751E03D0DC5F", Data([0x02]))
        waitForHeartBeats(2)
        XCTAssertEqual(recorder.heartBeats, 2)
        XCTAssertNotNil(UserDefaults.standard.timeStampOfLastHeartBeat)
    }

    // MARK: - Generic BluetoothTransmitter

    func testGenericTransmitterStateWithoutConnection() {
        let transmitter = OmniPodHeartBeatTransmitter(address: nil, name: nil, bluetoothTransmitterDelegate: recorder)
        addTeardownBlock { transmitter.prepareForRelease() }
        XCTAssertNil(transmitter.deviceAddress)
        XCTAssertNil(transmitter.deviceName)
        XCTAssertNil(transmitter.signalStrength)
        XCTAssertFalse(transmitter.isSignalStrengthConnected)
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), type: .withResponse))
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), characteristicToWriteTo: BLECoverageCharacteristic(uuid: "F001", value: nil), type: .withResponse))
        XCTAssertNil(transmitter.scanOptions())
        XCTAssertFalse(transmitter.shouldTimeoutStalledConnectionSetup())
        XCTAssertFalse(transmitter.shouldSetNotifyValueInline())
        transmitter.setNotifyValue(true, for: BLECoverageCharacteristic(uuid: "F001", value: nil))
        transmitter.updateExpectedDeviceName(name: "BOARD-2")
        transmitter.initiatePairing()
        transmitter.readSignalStrength()
        transmitter.cancelConnectionTimer()
        transmitter.cancelConnectionSetupTimeout()
        transmitter.disconnect()
        let done = expectation(description: "central")
        transmitter.runOnCentralQueue { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertNil(transmitter.getConnectionStatus())
    }

    func testKnownAddressIsExposedImmediately() {
        let address = UUID().uuidString
        let transmitter = M5StackBluetoothTransmitter(address: address, name: "M5Stack-1", bluetoothTransmitterDelegate: recorder,
                                                      m5StackBluetoothTransmitterDelegate: recorder, blePassword: nil, bluetoothPeripheralType: .M5StackType)
        addTeardownBlock { transmitter.prepareForRelease() }
        XCTAssertEqual(transmitter.deviceAddress, address)
        XCTAssertEqual(transmitter.deviceName, "M5Stack-1")
    }

    // MARK: - Helpers

    private func makeM5Stack(type: BluetoothPeripheralType = .M5StackType) -> M5StackBluetoothTransmitter {
        let transmitter = M5StackBluetoothTransmitter(address: nil, name: nil, bluetoothTransmitterDelegate: recorder,
                                                      m5StackBluetoothTransmitterDelegate: recorder, blePassword: "pw", bluetoothPeripheralType: type)
        addTeardownBlock { transmitter.prepareForRelease() }
        return transmitter
    }

    private func makeMedtrum() -> CGMMedtrumTouchCareNanoTransmitter {
        let transmitter = CGMMedtrumTouchCareNanoTransmitter(address: nil, name: nil, bluetoothTransmitterDelegate: recorder, cGMTransmitterDelegate: cgmRecorder)
        addTeardownBlock { transmitter.prepareForRelease() }
        return transmitter
    }

    private func receive(_ transmitter: BluetoothTransmitter, _ uuid: String, _ value: Data) {
        let characteristic = BLECoverageCharacteristic(uuid: uuid, value: value)
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateValueFor: characteristic, error: nil)
    }

    private func waitForHeartBeats(_ count: Int) {
        let deadline = Date().addingTimeInterval(3)
        while recorder.heartBeats < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func medtrumPacket(counter: UInt16, raw: UInt16, history: [UInt16], factor: UInt16) -> Data {
        func le(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        return Data([0x00, 0x02, 0x00, 0x00] + le(counter) + [0x00, 0x00] + le(raw) + le(history[0]) + le(history[1]) + le(history[2]) + [0x00, 0x00] + le(factor))
    }
}

final class BLECoverageCharacteristic: CBMutableCharacteristic {
    private var fakeValue: Data?
    private let fakeService: CBService?
    private let notifying: Bool

    override var value: Data? {
        get { fakeValue }
        set { fakeValue = newValue }
    }
    override var service: CBService? { fakeService }
    override var isNotifying: Bool { notifying }

    init(uuid: String, value: Data?, service: CBService? = nil, notifying: Bool = false) {
        fakeService = service
        self.notifying = notifying
        super.init(type: CBUUID(string: uuid), properties: [.read, .notify, .write], value: nil, permissions: [.readable])
        fakeValue = value
    }
}

final class BLECoverageRecorder: BluetoothTransmitterDelegate, M5StackBluetoothTransmitterDelegate {
    var heartBeats = 0
    var batteryLevels = [Int]()
    var passwords = [String]()
    var authentications = [Bool]()
    var readyCount = 0
    var allParametersCount = 0
    var passwordMissingCount = 0
    var resetRequiredCount = 0
    var connects = 0
    var disconnects = 0

    func didConnectTo(bluetoothTransmitter: BluetoothTransmitter) { connects += 1 }
    func didDisconnectFrom(bluetoothTransmitter: BluetoothTransmitter) { disconnects += 1 }
    func deviceDidUpdateBluetoothState(state: CBManagerState, bluetoothTransmitter: BluetoothTransmitter) {}
    func transmitterNeedsPairing(bluetoothTransmitter: BluetoothTransmitter) {}
    func successfullyPaired() {}
    func pairingFailed() {}
    func error(message: String) {}
    func heartBeat() { heartBeats += 1 }
    func didUpdateBatteryLevel(_ batteryLevel: Int, bluetoothTransmitter: BluetoothTransmitter) { batteryLevels.append(batteryLevel) }

    func isReadyToReceiveData(m5StackBluetoothTransmitter: M5StackBluetoothTransmitter) { readyCount += 1 }
    func isAskingForAllParameters(m5StackBluetoothTransmitter: M5StackBluetoothTransmitter) { allParametersCount += 1 }
    func newBlePassWord(newBlePassword: String, m5StackBluetoothTransmitter: M5StackBluetoothTransmitter) { passwords.append(newBlePassword) }
    func authentication(success: Bool, m5StackBluetoothTransmitter: M5StackBluetoothTransmitter) { authentications.append(success) }
    func blePasswordMissing(m5StackBluetoothTransmitter: M5StackBluetoothTransmitter) { passwordMissingCount += 1 }
    func m5StackResetRequired(m5StackBluetoothTransmitter: M5StackBluetoothTransmitter) { resetRequiredCount += 1 }
    func receivedBattery(level: Int, m5StackBluetoothTransmitter: M5StackBluetoothTransmitter) { batteryLevels.append(level) }
}
