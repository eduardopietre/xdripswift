//
//  DexcomCoverageG7TransmitterTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import CoreData
import XCTest
@testable import xdrip

final class DexcomCoverageG7TransmitterTests: XCTestCase {
    private let service = "F8083532-849E-531C-C594-30F1F86A4EA5"
    private let communication = "F8083533-849E-531C-C594-30F1F86A4EA5"
    private let writeControl = "F8083534-849E-531C-C594-30F1F86A4EA5"
    private let receiveAuthentication = "F8083535-849E-531C-C594-30F1F86A4EA5"
    private let backfill = "F8083536-849E-531C-C594-30F1F86A4EA5"
    private let authStream = "F8083538-849E-531C-C594-30F1F86A4EA5"
    private let transmitterID = "DXCMG7CV"
    private var defaults: DexcomCoverageDefaultsSnapshot!
    private var recorder: DexcomCoverageRecorder!
    private let peripheralObject = NSObject()

    override func setUp() {
        super.setUp()
        defaults = DexcomCoverageDefaultsSnapshot()
        UserDefaults.standard.previousRawGlucoseValues = nil
        DexcomG7AuthBridge.clearPersistedSharedKeys(forTransmitterID: transmitterID)
        recorder = DexcomCoverageRecorder()
    }

    override func tearDown() {
        DexcomG7AuthBridge.clearPersistedSharedKeys(forTransmitterID: transmitterID)
        recorder = nil
        defaults.restore()
        super.tearDown()
    }

    // MARK: - Pure helpers

    // MARK: - Configuration

    func testPrimaryRequiresFourDigitPairingCode() {
        XCTAssertFalse(makeTransmitter(useOtherApp: false, pairingCode: "1234").useOtherApp)
        XCTAssertTrue(makeTransmitter(useOtherApp: false, pairingCode: "12a4").useOtherApp)
        XCTAssertTrue(makeTransmitter(useOtherApp: false, pairingCode: "123").useOtherApp)
        XCTAssertTrue(makeTransmitter(useOtherApp: false, pairingCode: nil).useOtherApp)
        XCTAssertTrue(makeTransmitter(useOtherApp: true, pairingCode: "1234").useOtherApp)
    }

    func testStaticConfiguration() {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        XCTAssertEqual(transmitter.cgmTransmitterType(), .dexcomG7)
        XCTAssertEqual(transmitter.getCBUUID_Service(), service)
        XCTAssertEqual(transmitter.getCBUUID_Receive(), receiveAuthentication)
        XCTAssertTrue(transmitter.isWebOOPEnabled())
        XCTAssertTrue(transmitter.overruleIsWebOOPEnabled())
        XCTAssertTrue(transmitter.shouldWarnOnLargeCalibrationStep())
        XCTAssertTrue(transmitter.isNewDeviceDiscovery)
        XCTAssertNil(transmitter.transmitterCalibrationStatus())
        XCTAssertEqual(transmitter.bluetoothSlot, .mobileApp)
        XCTAssertNotNil(transmitter.scanOptions()?[CBCentralManagerScanOptionAllowDuplicatesKey])
        XCTAssertNil(makeTransmitter(useOtherApp: false, pairingCode: "1234").scanOptions())
    }

    func testMaximumSensorAgeFromSessionLengthOrName() {
        XCTAssertEqual(makeTransmitter(useOtherApp: true, pairingCode: nil).maxSensorAgeInDays(), 10.5)
        XCTAssertEqual(makeTransmitter(useOtherApp: true, pairingCode: nil, sensorSessionLength: 1_339_200).maxSensorAgeInDays(), 15.5)
        XCTAssertEqual(makeTransmitter(useOtherApp: true, pairingCode: nil, sensorSessionLength: 12).maxSensorAgeInDays(), 10.5)
        let stelo = makeTransmitter(useOtherApp: true, pairingCode: nil, address: UUID().uuidString, name: "DX01ABCD")
        XCTAssertEqual(stelo.maxSensorAgeInDays(), 15.5)
        XCTAssertFalse(stelo.isNewDeviceDiscovery)
        XCTAssertEqual(UserDefaults.standard.activeSensorTransmitterId, "DX01ABCD")
    }

    func testHasSixIdenticalValuesUsesRestoredHistory() {
        UserDefaults.standard.previousRawGlucoseValues = [100, 100, 100, 100, 100, 100, 90]
        XCTAssertTrue(makeTransmitter(useOtherApp: true, pairingCode: nil).hasSixIdenticalValues())
        UserDefaults.standard.previousRawGlucoseValues = [100, 100, 100, 100, 100, 101]
        XCTAssertFalse(makeTransmitter(useOtherApp: true, pairingCode: nil).hasSixIdenticalValues())
        UserDefaults.standard.previousRawGlucoseValues = [100, 100]
        XCTAssertFalse(makeTransmitter(useOtherApp: true, pairingCode: nil).hasSixIdenticalValues())
    }

    // MARK: - Coexistence glucose

    func testCoexistenceGlucoseJoinsWithClockPacket() throws {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        receive(transmitter, writeControl, coexistenceGlucose(transmitterTime: 99_900, value: 145, state: 0x06))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        receive(transmitter, writeControl, clock(transmitterTime: 100_000, sensorCounter: 10_000))
        drainMain()
        let reading = try XCTUnwrap(recorder.glucoseBatches.first?.first)
        XCTAssertEqual(reading.glucoseLevelRaw, 145)
        XCTAssertEqual(reading.timeStamp.timeIntervalSinceNow, -100, accuracy: 5)
        XCTAssertEqual(recorder.sensorAges.first ?? 0, 89_900, accuracy: 0.001)
        XCTAssertEqual(recorder.sensorStatuses, ["OK / Calibrated"])
        XCTAssertEqual(recorder.healthEvents, [.recovered(source: .dexcom)])
        let start = try XCTUnwrap(recorder.sensorStartDates.first ?? nil)
        XCTAssertEqual(reading.timeStamp.timeIntervalSince(start), 89_900, accuracy: 0.001)
    }

    func testCoexistenceClockBeforeGlucoseAlsoWorksAndNegativeAgeIsDropped() {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        receive(transmitter, writeControl, clock(transmitterTime: 100_000, sensorCounter: 10_000))
        receive(transmitter, writeControl, coexistenceGlucose(transmitterTime: 99_000, value: 110, state: 0x06))
        drainMain()
        XCTAssertEqual(recorder.glucoseBatches.count, 1)
        receive(transmitter, writeControl, clock(transmitterTime: 100_000, sensorCounter: 10_000))
        receive(transmitter, writeControl, coexistenceGlucose(transmitterTime: 9_000, value: 110, state: 0x06))
        drainMain()
        XCTAssertEqual(recorder.glucoseBatches.count, 1)
    }

    func testCoexistencePacketsAreIgnoredInPrimaryMode() {
        let transmitter = makeTransmitter(useOtherApp: false, pairingCode: "1234")
        receive(transmitter, writeControl, coexistenceGlucose(transmitterTime: 99_900, value: 145, state: 0x06))
        receive(transmitter, writeControl, clock(transmitterTime: 100_000, sensorCounter: 10_000))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
    }

    // MARK: - Primary glucose

    func testPrimaryGlucoseIsDelivered() throws {
        let transmitter = makeTransmitter(useOtherApp: false, pairingCode: "1234")
        receive(transmitter, writeControl, primaryGlucose(status: 0, transmitterTime: 86_400, age: 30, value: 0x00A0, state: 0x06))
        drainMain()
        let reading = try XCTUnwrap(recorder.glucoseBatches.first?.first)
        XCTAssertEqual(reading.glucoseLevelRaw, 160)
        XCTAssertEqual(recorder.sensorAges, [86_370])
        XCTAssertEqual(reading.timeStamp.timeIntervalSinceNow, -30, accuracy: 5)
    }

    func testPrimaryGlucoseWithErrorStatusOnlyReportsHealth() {
        let transmitter = makeTransmitter(useOtherApp: false, pairingCode: "1234")
        receive(transmitter, writeControl, primaryGlucose(status: 0x80, transmitterTime: 86_400, age: 30, value: 0x00A0, state: 0x1B))
        receive(transmitter, writeControl, Data([0x4E, 0x00, 0x01]))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        XCTAssertEqual(recorder.sensorStatuses, ["Sensor failed"])
        XCTAssertEqual(recorder.healthEvents, [.terminal(source: .dexcom, reason: .dexcomSensorFailure)])
    }

    func testExpiredSensorReadingIsNotDelivered() {
        let transmitter = makeTransmitter(useOtherApp: false, pairingCode: "1234")
        receive(transmitter, writeControl, primaryGlucose(status: 0, transmitterTime: 11 * 86_400, age: 0, value: 120, state: 0x06))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        let longSession = makeTransmitter(useOtherApp: false, pairingCode: "1234", sensorSessionLength: 1_339_200)
        receive(longSession, writeControl, primaryGlucose(status: 0, transmitterTime: 11 * 86_400, age: 0, value: 120, state: 0x06))
        drainMain()
        XCTAssertEqual(recorder.glucoseBatches.count, 1)
    }

    func testSixIdenticalReadingsAreSuppressed() {
        UserDefaults.standard.previousRawGlucoseValues = [120, 120, 120, 120, 120]
        let transmitter = makeTransmitter(useOtherApp: false, pairingCode: "1234")
        receive(transmitter, writeControl, primaryGlucose(status: 0, transmitterTime: 86_400, age: 0, value: 120, state: 0x06))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        XCTAssertTrue(transmitter.hasSixIdenticalValues())
        receive(transmitter, writeControl, primaryGlucose(status: 0, transmitterTime: 86_700, age: 0, value: 121, state: 0x06))
        drainMain()
        XCTAssertEqual(recorder.glucoseBatches.count, 1)
        XCTAssertEqual(UserDefaults.standard.previousRawGlucoseValues, [121, 120, 120, 120, 120, 120])
    }

    // MARK: - Diagnostics

    func testExtendedVersionUpdatesLifetime() {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        receive(transmitter, writeControl, extendedVersion(sessionLength: 1_339_200))
        drainMain()
        XCTAssertEqual(recorder.sessionLengths, [1_339_200])
        XCTAssertEqual(transmitter.maxSensorAgeInDays(), 15.5)
        receive(transmitter, writeControl, extendedVersion(sessionLength: 864_000))
        receive(transmitter, writeControl, Data([0x52, 0x00]))
        drainMain()
        XCTAssertEqual(recorder.sessionLengths, [1_339_200])
    }

    func testFullVersionIsReported() throws {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        receive(transmitter, writeControl, Data([0x4A, 0x00, 2, 18, 2, 88] + le32(1234) + le32(5678) + [1, 2, 3, 4, 5, 6]))
        receive(transmitter, writeControl, Data([0x4A, 0x00, 2]))
        drainMain()
        let version = try XCTUnwrap(recorder.versions.first)
        XCTAssertEqual(recorder.versions.count, 1)
        XCTAssertEqual(version.firmwareVersion, "2.18.2.88")
        XCTAssertEqual(version.buildVersion, 1234)
        XCTAssertEqual(version.versionCode, 5678)
    }

    func testBatteryIsReportedOnlyWhenDue() {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        let packet = Data([0x22, 0x00, 0x3C, 0x01, 0x2C, 0x01, 0xA0, 0x05, 0x0A, 0x1E])
        receive(transmitter, writeControl, packet)
        receive(transmitter, writeControl, packet)
        receive(transmitter, writeControl, Data([0x22, 0x00]))
        drainMain()
        XCTAssertEqual(recorder.g7Batteries.map(\.1), [true])
        XCTAssertEqual(recorder.cgmBatteryInfos, [.dexcom(family: .g7, voltageA: 316, voltageB: 300, resist: 1440, runtime: 10, temperature: 30)])
        let older = makeTransmitter(useOtherApp: true, pairingCode: nil, batteryLastReadDate: Date().addingTimeInterval(-3 * 3600))
        receive(older, writeControl, packet)
        drainMain()
        XCTAssertEqual(recorder.g7Batteries.map(\.1), [true, false])
    }

    // MARK: - Backfill

    func testBackfillIsBufferedUntilClockAndFlushedSortedOnFinish() throws {
        let transmitter = makeTransmitter(useOtherApp: false, pairingCode: "1234")
        receive(transmitter, backfill, backfillFrame(seconds: 85_800, value: 100))
        receive(transmitter, writeControl, primaryGlucose(status: 0, transmitterTime: 86_400, age: 0, value: 130, state: 0x06))
        receive(transmitter, backfill, backfillFrame(seconds: 86_100, value: 115))
        receive(transmitter, backfill, backfillFrame(seconds: 86_100, value: 116))
        receive(transmitter, backfill, backfillFrame(seconds: 90_000, value: 200))
        receive(transmitter, backfill, Data([0x01, 0x02]))
        drainMain()
        XCTAssertEqual(recorder.glucoseBatches.count, 1)
        receive(transmitter, writeControl, Data([0x59]))
        drainMain()
        let batch = try XCTUnwrap(recorder.glucoseBatches.last)
        XCTAssertEqual(batch.map(\.glucoseLevelRaw), [115, 100])
        XCTAssertTrue(batch.allSatisfy { $0.backfilledAt != nil })
        XCTAssertGreaterThan(batch[0].timeStamp, batch[1].timeStamp)
        receive(transmitter, writeControl, Data([0x59]))
        drainMain()
        XCTAssertEqual(recorder.glucoseBatches.count, 2)
    }

    // MARK: - Calibration

    func testCalibrationQueueingValidatesValueAndAge() throws {
        let coreData = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreData.mainManagedObjectContext
        let sensor = Sensor(startDate: Date().addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        transmitter.calibrate(calibration: calibration(bg: 30, timeStamp: Date(), sensor: sensor, context: context))
        flushCentral(transmitter)
        XCTAssertNil(transmitter.transmitterCalibrationStatus())
        transmitter.calibrate(calibration: calibration(bg: 120, timeStamp: Date().addingTimeInterval(-86_400), sensor: sensor, context: context))
        flushCentral(transmitter)
        XCTAssertNil(transmitter.transmitterCalibrationStatus())
        transmitter.calibrate(calibration: calibration(bg: 120, timeStamp: Date(), sensor: sensor, context: context))
        flushCentral(transmitter)
        XCTAssertEqual(transmitter.transmitterCalibrationStatus(), .queued)
    }

    func testPendingCalibrationAtInitialisationIsQueued() {
        let coreData = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreData.mainManagedObjectContext
        let sensor = Sensor(startDate: Date().addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let pending = calibration(bg: 110, timeStamp: Date(), sensor: sensor, context: context)
        XCTAssertEqual(makeTransmitter(useOtherApp: true, pairingCode: nil, calibration: pending).transmitterCalibrationStatus(), .queued)
        pending.sentToTransmitter = true
        XCTAssertNil(makeTransmitter(useOtherApp: true, pairingCode: nil, calibration: pending).transmitterCalibrationStatus())
    }

    func testBoundsRecordDrivesNotPermittedStatus() {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        receive(transmitter, writeControl, bounds(processing: 3, permitted: false))
        XCTAssertEqual(transmitter.transmitterCalibrationStatus(), .notPermitted)
        receive(transmitter, writeControl, bounds(processing: 0, permitted: true))
        XCTAssertNil(transmitter.transmitterCalibrationStatus())
        receive(transmitter, writeControl, bounds(processing: 3, permitted: true))
        XCTAssertEqual(transmitter.transmitterCalibrationStatus(), .completedHigh)
        receive(transmitter, writeControl, bounds(processing: 4, permitted: true))
        XCTAssertEqual(transmitter.transmitterCalibrationStatus(), .completedLow)
        receive(transmitter, writeControl, bounds(processing: 2, permitted: true))
        XCTAssertEqual(transmitter.transmitterCalibrationStatus(), .processing)
        receive(transmitter, writeControl, Data([0x32, 0x00]))
        receive(transmitter, writeControl, Data([0x34, 0x00, 0x00, 0x00]))
        receive(transmitter, writeControl, Data([0x34, 0x00]))
        XCTAssertEqual(transmitter.transmitterCalibrationStatus(), .processing)
    }

    // MARK: - Characteristics and authentication plumbing

    func testCoexistenceDiscoveryAndAuthenticationAreObservedPassively() {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        let characteristics = discover(transmitter, notifying: [writeControl])
        receive(transmitter, receiveAuthentication, Data([0x05, 0x01, 0x01]))
        receive(transmitter, receiveAuthentication, Data([0x05, 0x00, 0x02]))
        receive(transmitter, receiveAuthentication, Data([0x05]))
        receive(transmitter, authStream, Data(count: 160))
        receive(transmitter, communication, Data([0x01]))
        onCentral(transmitter) {
            for characteristic in characteristics {
                transmitter.peripheral(dexcomCoveragePeripheral(self.peripheralObject), didUpdateNotificationStateFor: characteristic, error: nil)
            }
        }
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testErrorsAndUnknownCharacteristicsAreIgnored() {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        onCentral(transmitter) {
            let characteristic = DexcomCoverageFakeCharacteristic(uuid: self.writeControl, value: self.primaryGlucose(status: 0, transmitterTime: 86_400, age: 0, value: 150, state: 6))
            transmitter.peripheral(dexcomCoveragePeripheral(self.peripheralObject), didUpdateValueFor: characteristic, error: NSError(domain: "test", code: 1))
            transmitter.peripheral(dexcomCoveragePeripheral(self.peripheralObject), didUpdateNotificationStateFor: characteristic, error: NSError(domain: "test", code: 2))
            let unknown = DexcomCoverageFakeCharacteristic(uuid: "F80835FF-849E-531C-C594-30F1F86A4EA5", value: Data([0x4E]))
            transmitter.peripheral(dexcomCoveragePeripheral(self.peripheralObject), didUpdateValueFor: unknown, error: nil)
            let service = CBMutableService(type: CBUUID(string: self.service), primary: true)
            transmitter.peripheral(dexcomCoveragePeripheral(self.peripheralObject), didDiscoverCharacteristicsFor: service, error: NSError(domain: "test", code: 3))
            transmitter.peripheral(dexcomCoveragePeripheral(self.peripheralObject), didDiscoverCharacteristicsFor: service, error: nil)
        }
        receive(transmitter, writeControl, Data([0xEE]))
        receive(transmitter, writeControl, Data([0x06, 0x01]))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
    }

    func testAuthenticationTransportCallbacksAreSafeWithoutConnection() {
        let transmitter = makeTransmitter(useOtherApp: false, pairingCode: "1234")
        let control = DexcomCoverageFakeCharacteristic(uuid: receiveAuthentication)
        onCentral(transmitter) {
            transmitter.authSessionSetNotifyValue(true, for: control)
            XCTAssertFalse(transmitter.authSessionWrite(Data([0x01]), to: control, type: .withResponse))
            transmitter.authSessionRequiresCleanReconnect()
            transmitter.authSessionDidRejectPersistedKey()
            transmitter.authSessionDidFail("failure")
            transmitter.authSessionDidProgress("progress")
        }
        let scheduled = expectation(description: "scheduled")
        transmitter.authSessionSchedule(after: 0.01) { scheduled.fulfill() }
        wait(for: [scheduled], timeout: 2)
    }

    func testConfigurationTransitions() {
        let transmitter = makeTransmitter(useOtherApp: true, pairingCode: nil)
        transmitter.transitionToUseOtherApp(false)
        flushCentral(transmitter)
        XCTAssertTrue(transmitter.useOtherApp)
        transmitter.transitionToPairingCode("12")
        transmitter.transitionToPairingCode("4321")
        transmitter.transitionToUseOtherApp(false)
        flushCentral(transmitter)
        XCTAssertFalse(transmitter.useOtherApp)
        transmitter.transitionToBluetoothSlot(.smartWatch)
        transmitter.transitionToBluetoothSlot(.smartWatch)
        flushCentral(transmitter)
        XCTAssertEqual(transmitter.bluetoothSlot, .smartWatch)
        transmitter.transitionToUseOtherApp(true)
        flushCentral(transmitter)
        XCTAssertTrue(transmitter.useOtherApp)
    }

    // MARK: - Helpers

    private func makeTransmitter(useOtherApp: Bool, pairingCode: String?, sensorSessionLength: TimeInterval? = nil,
                                 address: String? = nil, name: String? = nil, batteryLastReadDate: Date? = nil,
                                 calibration: Calibration? = nil) -> CGMG7Transmitter {
        let transmitter = CGMG7Transmitter(address: address, name: name, transmitterID: transmitterID, useOtherApp: useOtherApp,
                                           pairingCode: pairingCode, bluetoothSlot: .mobileApp, sensorSessionLength: sensorSessionLength,
                                           firmwareVersion: nil, firmwareBuildVersion: nil, firmwareVersionCode: nil,
                                           batteryLastReadDate: batteryLastReadDate, calibrationToSendToTransmitter: calibration,
                                           bluetoothTransmitterDelegate: recorder, cGMG7TransmitterDelegate: recorder, cGMTransmitterDelegate: recorder)
        addTeardownBlock { transmitter.prepareForRelease() }
        return transmitter
    }

    private func onCentral(_ transmitter: CGMG7Transmitter, _ block: @escaping () -> Void) {
        let done = expectation(description: "central")
        transmitter.runOnCentralQueue {
            block()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    private func flushCentral(_ transmitter: CGMG7Transmitter) {
        onCentral(transmitter) {}
        onCentral(transmitter) {}
    }

    private func receive(_ transmitter: CGMG7Transmitter, _ uuid: String, _ value: Data) {
        onCentral(transmitter) {
            let characteristic = DexcomCoverageFakeCharacteristic(uuid: uuid, value: value)
            transmitter.peripheral(dexcomCoveragePeripheral(self.peripheralObject), didUpdateValueFor: characteristic, error: nil)
        }
    }

    @discardableResult
    private func discover(_ transmitter: CGMG7Transmitter, notifying: Set<String>) -> [DexcomCoverageFakeCharacteristic] {
        let characteristics = [communication, writeControl, receiveAuthentication, backfill, authStream, "F80835AA-849E-531C-C594-30F1F86A4EA5"]
            .map { DexcomCoverageFakeCharacteristic(uuid: $0, notifying: notifying.contains($0)) }
        let service = CBMutableService(type: CBUUID(string: self.service), primary: true)
        service.characteristics = characteristics
        onCentral(transmitter) {
            transmitter.peripheral(dexcomCoveragePeripheral(self.peripheralObject), didDiscoverCharacteristicsFor: service, error: nil)
        }
        return characteristics
    }

    private func calibration(bg: Double, timeStamp: Date, sensor: Sensor, context: NSManagedObjectContext) -> Calibration {
        Calibration(timeStamp: timeStamp, sensor: sensor, bg: bg, rawValue: 0, adjustedRawValue: 0, sensorConfidence: 0, rawTimeStamp: timeStamp,
                    slope: 1, intercept: 0, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 0, slopeConfidence: 0,
                    deviceName: nil, nsManagedObjectContext: context)
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private func clock(transmitterTime: UInt32, sensorCounter: UInt32) -> Data {
        Data([0x25, 0x00] + le32(transmitterTime) + le32(sensorCounter))
    }

    private func coexistenceGlucose(transmitterTime: UInt32, value: UInt16, state: UInt8) -> Data {
        Data([0x31, 0x00, 0, 0, 0, 0] + le32(transmitterTime) + [UInt8(value & 0xFF), UInt8(value >> 8), state, 0, 0, 0])
    }

    private func primaryGlucose(status: UInt8, transmitterTime: UInt32, age: UInt16, value: UInt16, state: UInt8) -> Data {
        Data([0x4E, status] + le32(transmitterTime) + [0x01, 0x00, 0x00, 0x00, UInt8(age & 0xFF), UInt8(age >> 8),
                                                       UInt8(value & 0xFF), UInt8(value >> 8), state, 0x00, 0xFF, 0xFF, 0x00])
    }

    private func extendedVersion(sessionLength: UInt32) -> Data {
        Data([0x52, 0x00] + le32(sessionLength) + [0x08, 0x07] + le32(1) + [0x01, 0x0F, 0x00])
    }

    private func backfillFrame(seconds: UInt32, value: UInt16) -> Data {
        Data(le32(seconds) + [UInt8(value & 0xFF), UInt8(value >> 8), 0x06, 0x00, 0x00])
    }

    private func bounds(processing: UInt8, permitted: Bool) -> Data {
        Data([0x32, 0x00, 0x01] + le32(5) + [0x64, 0x00] + le32(1000) + [processing, permitted ? 1 : 0, 0x02] + le32(1100))
    }
}
