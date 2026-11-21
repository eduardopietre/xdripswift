//
//  DexcomCoverageG5TransmitterTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import CoreData
import XCTest
@testable import xdrip

final class DexcomCoverageG5TransmitterTests: XCTestCase {
    private let receiveAuthentication = "F8083535-849E-531C-C594-30F1F86A4EA5"
    private let writeControl = "F8083534-849E-531C-C594-30F1F86A4EA5"
    private let backfill = "F8083536-849E-531C-C594-30F1F86A4EA5"
    private var defaults: DexcomCoverageDefaultsSnapshot!
    private var recorder: DexcomCoverageRecorder!
    private let peripheralObject = NSObject()

    override func setUp() {
        super.setUp()
        defaults = DexcomCoverageDefaultsSnapshot()
        UserDefaults.standard.activeSensorStartDate = nil
        UserDefaults.standard.dexcomSensorSessionIdentityData = nil
        recorder = DexcomCoverageRecorder()
    }

    override func tearDown() {
        recorder = nil
        defaults.restore()
        super.tearDown()
    }

    // MARK: - Configuration

    func testFireflyConfigurationFlags() {
        let transmitter = makeTransmitter(id: "8GCOV1")
        XCTAssertEqual(transmitter.cgmTransmitterType(), .dexcom)
        XCTAssertEqual(UserDefaults.standard.activeSensorTransmitterId, "8GCOV1")
        XCTAssertEqual(transmitter.getCBUUID_Service(), "F8083532-849E-531C-C594-30F1F86A4EA5")
        XCTAssertEqual(transmitter.getCBUUID_Receive(), receiveAuthentication)
        XCTAssertTrue(transmitter.needsSensorStartCode())
        XCTAssertFalse(transmitter.needsSensorStartTime())
        XCTAssertTrue(transmitter.shouldWarnOnLargeCalibrationStep())
        XCTAssertFalse(transmitter.nonWebOOPAllowed())
        XCTAssertFalse(transmitter.isAnubisG6())
        XCTAssertEqual(transmitter.bluetoothSlot, .mobileApp)
    }

    func testClassicG5ConfigurationFlags() {
        let transmitter = makeTransmitter(id: "4ABCDE")
        XCTAssertFalse(transmitter.needsSensorStartCode())
        XCTAssertTrue(transmitter.needsSensorStartTime())
        XCTAssertFalse(transmitter.shouldWarnOnLargeCalibrationStep())
        XCTAssertTrue(transmitter.nonWebOOPAllowed())
        XCTAssertFalse(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.overruleIsWebOOPEnabled())
    }

    func testMaxSensorAgeUsesAnubisOverrideOnlyForAnubis() {
        UserDefaults.standard.activeSensorMaxSensorAgeInDaysOverridenAnubis = 30
        XCTAssertEqual(makeTransmitter(id: "8GCOV1").maxSensorAgeInDays(), 10)
        XCTAssertEqual(makeTransmitter(id: "8GCOV1", isAnubis: true).maxSensorAgeInDays(), 30)
        UserDefaults.standard.activeSensorMaxSensorAgeInDaysOverridenAnubis = 0
        XCTAssertEqual(makeTransmitter(id: "8GCOV1", isAnubis: true).maxSensorAgeInDays(), 10)
    }

    func testScaleRawValueDependsOnFamilyAndFirmware() {
        let g5 = makeTransmitter(id: "4ABCDE")
        XCTAssertEqual(g5.scaleRawValue(firmwareVersion: "1.0", rawValue: 1000), 1000)
        let g6 = makeTransmitter(id: "8GCOV1")
        XCTAssertEqual(g6.scaleRawValue(firmwareVersion: nil, rawValue: 1000), 1000)
        XCTAssertEqual(g6.scaleRawValue(firmwareVersion: "1.6.5.25", rawValue: 1000), 34_000)
        XCTAssertEqual(g6.scaleRawValue(firmwareVersion: "2.18.2.88", rawValue: 1_151_511_000), 100)
        XCTAssertEqual(g6.scaleRawValue(firmwareVersion: "3.0", rawValue: 1000), 1000)
    }

    func testSetWebOOPEnabledClearsSensorStatusOnlyOnChange() {
        let transmitter = makeTransmitter(id: "4ABCDE")
        transmitter.setWebOOPEnabled(enabled: false)
        drainMain()
        XCTAssertTrue(recorder.sensorStatuses.isEmpty)
        transmitter.setWebOOPEnabled(enabled: true)
        drainMain()
        XCTAssertTrue(transmitter.isWebOOPEnabled())
        XCTAssertTrue(transmitter.overruleIsWebOOPEnabled())
        XCTAssertEqual(recorder.sensorStatuses, [nil])
        XCTAssertEqual(recorder.sensorStartDates, [nil])
    }

    func testSensorWarmupConfirmationRequiresReport() {
        let transmitter = makeTransmitter(id: "8GCOV1")
        XCTAssertNil(transmitter.sensorWarmupConfirmationUntil(for: Date()))
    }

    func testShouldReportConfirmedSensorSessionTolerance() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(CGMG5Transmitter.shouldReportConfirmedSensorSession(reportedSensorStartDate: nil, receivedSensorStartDate: date))
        XCTAssertFalse(CGMG5Transmitter.shouldReportConfirmedSensorSession(reportedSensorStartDate: date.addingTimeInterval(15), receivedSensorStartDate: date))
        XCTAssertTrue(CGMG5Transmitter.shouldReportConfirmedSensorSession(reportedSensorStartDate: date.addingTimeInterval(-16), receivedSensorStartDate: date))
    }

    // MARK: - Incoming packets

    func testTransmitterVersionReportsFirmwareAndAnubis() {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        var body: [UInt8] = [0x4B, 0x00, 1, 6, 5, 25] + Array(repeating: 0, count: 11)
        body[13] = 180
        receive(transmitter, writeControl, Data(body).appendingCRC())
        drainMain()
        XCTAssertEqual(transmitter.firmware, "1.6.5.25")
        XCTAssertTrue(transmitter.isAnubis)
        XCTAssertEqual(recorder.firmwares, ["1.6.5.25"])
        XCTAssertEqual(recorder.anubisReports, [true])
    }

    func testBatteryStatusIsReportedOncePerReadPeriod() {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        let packet = Data([0x23, 0x00, 0x3C, 0x01, 0x2C, 0x01, 0xA0, 0x05, 0x5A, 0x1E]).appendingCRC()
        receive(transmitter, writeControl, packet)
        receive(transmitter, writeControl, packet)
        drainMain()
        let expected = TransmitterBatteryInfo.dexcom(family: .g5, voltageA: 316, voltageB: 300, resist: 1440, runtime: 90, temperature: 30)
        XCTAssertEqual(recorder.batteryInfos, [expected])
        XCTAssertEqual(recorder.cgmBatteryInfos, [expected])
    }

    func testBatteryStatusSuppressedWhenRecentlyRead() {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true, batteryLastReadDate: Date().addingTimeInterval(-60))
        receive(transmitter, writeControl, Data([0x23, 0x00, 0x3C, 0x01, 0x2C, 0x01, 0xA0, 0x05, 0x5A, 0x1E]).appendingCRC())
        receive(transmitter, writeControl, Data([0x23, 0x00, 0x3C]))
        drainMain()
        XCTAssertTrue(recorder.batteryInfos.isEmpty)
    }

    func testResetResponseReportsSuccess() {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        transmitter.reset(requested: true)
        receive(transmitter, writeControl, Data([0x43, 0x00]))
        receive(transmitter, writeControl, Data([0x43, 0x02]))
        receive(transmitter, writeControl, Data([0x43]))
        drainMain()
        XCTAssertEqual(recorder.resets, [true, false])
    }

    func testSessionStartResponseIsForwarded() {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        receive(transmitter, writeControl, Data([0x27, 0x00, 0x05] + le32(10) + le32(20) + le32(1000)))
        drainMain()
        XCTAssertEqual(recorder.sensorStatuses, ["transmitter end of life"])
        XCTAssertEqual(recorder.startResults.map(\.response), [.transmitterEndOfLife])
    }

    func testTransmitterTimeReportsSensorAndTransmitterStart() throws {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        receive(transmitter, writeControl, transmitterTime(transmitterTime: 100_000, sensorCounter: 20_000))
        drainMain()
        let transmitterStart = try XCTUnwrap(transmitter.transmitterStartDate)
        XCTAssertEqual(Date().timeIntervalSince(transmitterStart), 100_000, accuracy: 5)
        XCTAssertEqual(recorder.transmitterStartDates.count, 1)
        let sensorStart = try XCTUnwrap(recorder.sensorStartDates.compactMap { $0 }.first)
        XCTAssertEqual(sensorStart.timeIntervalSince(transmitterStart), 20_000, accuracy: 0.001)
    }

    func testCoexistenceGlucoseIsPublishedOnceSessionClockArrives() throws {
        let transmitterStart = Date().addingTimeInterval(-100_000)
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true, transmitterStartDate: transmitterStart)
        let g6Glucose: [UInt8] = [0x4F, 0x00, 1, 0, 0, 0] + le32(99_900) + [0x96, 0x00, 0x06, 0, 0, 0]
        receive(transmitter, writeControl, Data(g6Glucose))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        XCTAssertEqual(recorder.sensorStatuses, ["OK / Calibrated"])
        receive(transmitter, writeControl, transmitterTime(transmitterTime: 100_000, sensorCounter: 20_000))
        drainMain()
        drainMain()
        let reading = try XCTUnwrap(recorder.glucoseBatches.first?.first)
        XCTAssertEqual(reading.glucoseLevelRaw, 150)
        XCTAssertEqual(reading.timeStamp, transmitterStart.addingTimeInterval(99_900))
        XCTAssertEqual(recorder.newSensorDates.count, 1)
        XCTAssertEqual(recorder.healthEvents.first, .recovered(source: .dexcom))
        XCTAssertEqual(recorder.calibrationStates.map(\.0), [.okay])
    }

    func testCoexistenceConfirmsMatchingInternalSessionAndStoresIdentity() throws {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true, transmitterStartDate: Date().addingTimeInterval(-100_000))
        let clock = transmitterTime(transmitterTime: 100_000, sensorCounter: 20_000)
        let sensorStart = try XCTUnwrap(DexcomTransmitterTimeRxMessage(data: clock)?.sensorStartDate)
        UserDefaults.standard.activeSensorStartDate = sensorStart
        receive(transmitter, writeControl, Data([0x31, 0x00] + Array(repeating: 0, count: 8) + [0x78, 0x00, 0x06, 0x00]))
        receive(transmitter, writeControl, clock)
        drainMain()
        drainMain()
        XCTAssertTrue(recorder.newSensorDates.isEmpty)
        XCTAssertEqual(recorder.confirmedSessions.count, 1)
        let identity = try XCTUnwrap(UserDefaults.standard.dexcomSensorSessionIdentityData.flatMap { try? JSONDecoder().decode(DexcomSensorSessionIdentity.self, from: $0) })
        XCTAssertEqual(identity.transmitterID, "8GCOV1")
        XCTAssertEqual(identity.startCounter, 20_000)
        XCTAssertEqual(recorder.glucoseBatches.first?.first?.glucoseLevelRaw, 120)
    }

    func testSessionStoppedStatusReportsStop() {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        receive(transmitter, writeControl, Data([0x31, 0x00] + Array(repeating: 0, count: 8) + [0x00, 0x00, 0x01, 0x00]))
        drainMain()
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(recorder.sensorStatuses.last, "Session stopped")
    }

    func testWarmupStatusEnablesWarmupConfirmationForSameSession() throws {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        let clock = transmitterTime(transmitterTime: 100_000, sensorCounter: 99_000)
        let sensorStart = try XCTUnwrap(DexcomTransmitterTimeRxMessage(data: clock)?.sensorStartDate)
        receive(transmitter, writeControl, clock)
        receive(transmitter, writeControl, Data([0x31, 0x00] + Array(repeating: 0, count: 8) + [0x00, 0x00, 0x02, 0x00]))
        drainMain()
        drainMain()
        let until = try XCTUnwrap(transmitter.sensorWarmupConfirmationUntil(for: sensorStart))
        XCTAssertEqual(until.timeIntervalSinceNow, 600, accuracy: 10)
        XCTAssertNil(transmitter.sensorWarmupConfirmationUntil(for: sensorStart.addingTimeInterval(3600)))
        XCTAssertNil(transmitter.sensorWarmupConfirmationUntil(for: sensorStart, now: Date().addingTimeInterval(700)))
        XCTAssertEqual(recorder.healthEvents.first, .recovered(source: .dexcom))
    }

    func testClassicG5SensorDataDeliversRawReadingOnce() throws {
        let transmitter = makeTransmitter(id: "4ABCDE")
        let packet = Data([0x2F, 0x00] + Array(repeating: 0, count: 8) + le32(150_000)).appendingCRC()
        receive(transmitter, writeControl, packet)
        receive(transmitter, writeControl, packet)
        drainMain()
        XCTAssertEqual(recorder.glucoseBatches.count, 1)
        XCTAssertEqual(recorder.glucoseBatches.first?.first?.glucoseLevelRaw, 150_000)
    }

    func testSensorDataLowBatterySentinelRaisesTerminalHealthEvent() {
        let transmitter = makeTransmitter(id: "4ABCDE")
        receive(transmitter, writeControl, Data([0x2F, 0x00] + Array(repeating: 0, count: 8) + le32(2_096_896)).appendingCRC())
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        XCTAssertEqual(recorder.healthEvents, [.terminal(source: .dexcom, reason: .dexcomTransmitterBatteryFailure)])
    }

    func testSensorDataIsIgnoredInCoexistenceAndWhenMalformed() {
        let coexistence = makeTransmitter(id: "4ABCDE", useOtherApp: true)
        receive(coexistence, writeControl, Data([0x2F, 0x00] + Array(repeating: 0, count: 8) + le32(150_000)).appendingCRC())
        let primary = makeTransmitter(id: "4ABCDE")
        receive(primary, writeControl, Data([0x2F, 0x00, 0x01]))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
    }

    func testUnpairedAuthenticationStatusRequestsPairing() {
        let transmitter = makeTransmitter(id: "8GCOV1")
        receive(transmitter, receiveAuthentication, Data([0x05, 0x01, 0x02]))
        receive(transmitter, receiveAuthentication, Data([0x05, 0x01]))
        drainMain()
        XCTAssertEqual(recorder.pairingRequests, 1)
        let coexistence = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        receive(coexistence, receiveAuthentication, Data([0x05, 0x01, 0x02]))
        receive(coexistence, receiveAuthentication, Data([0x05, 0x01, 0x01]))
        drainMain()
        XCTAssertEqual(recorder.pairingRequests, 1)
    }

    func testPairingConfirmationIsReportedByFirstSensorData() {
        let transmitter = makeTransmitter(id: "4ABCDE")
        receive(transmitter, writeControl, Data([0x08, 0x01]))
        receive(transmitter, writeControl, Data([0x2F, 0x00, 0x01]))
        drainMain()
        XCTAssertEqual(recorder.pairedCount, 1)
        let coexistence = makeTransmitter(id: "4ABCDE", useOtherApp: true)
        receive(coexistence, writeControl, Data([0x08, 0x01]))
        receive(coexistence, writeControl, Data([0x2F, 0x00, 0x01]))
        drainMain()
        XCTAssertEqual(recorder.pairedCount, 1)
    }

    func testFireflyPrimaryCycleDeliversReadingAfterBackfillRequest() throws {
        let transmitter = makeTransmitter(id: "8GCOV1", firmware: "1.6.5.25")
        let clock = transmitterTime(transmitterTime: 200_000, sensorCounter: 150_000)
        receive(transmitter, writeControl, clock)
        receive(transmitter, writeControl, Data([0x31, 0x00] + Array(repeating: 0, count: 8) + [0x8C, 0x00, 0x06, 0x00]))
        drainMain()
        XCTAssertEqual(recorder.newSensorDates.count, 1)
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        receive(transmitter, writeControl, clock)
        receive(transmitter, writeControl, clock)
        drainMain()
        drainMain()
        XCTAssertEqual(recorder.glucoseBatches.count, 1)
        XCTAssertEqual(recorder.glucoseBatches.first?.map(\.glucoseLevelRaw), [140])
        XCTAssertEqual(recorder.calibrationStates.map(\.0), [.okay])
    }

    func testFireflyPrimaryDeliversDecodedBackfillWithReading() throws {
        let transmitter = makeTransmitter(id: "8GCOV1", firmware: "1.6.5.25")
        let clock = transmitterTime(transmitterTime: 200_000, sensorCounter: 150_000)
        receive(transmitter, writeControl, clock)
        receive(transmitter, writeControl, Data([0x31, 0x00] + Array(repeating: 0, count: 8) + [0x8C, 0x00, 0x06, 0x00]))
        receive(transmitter, writeControl, clock)
        let stream: [UInt8] = [0, 0, 0, 0] + le32(199_400) + [0x78, 0x00, 0x06, 0x00] + le32(199_700) + [0x82, 0x00, 0x07, 0x00]
        receive(transmitter, backfill, Data([0x01, 0x00] + stream.prefix(18)))
        receive(transmitter, backfill, Data([0x02, 0x00] + stream.dropFirst(18)))
        receive(transmitter, writeControl, Data([0x51, 0x00, 0x01, 0x01] + le32(199_000) + le32(200_000) + Array(repeating: 0, count: 8)))
        drainMain()
        drainMain()
        let batch = try XCTUnwrap(recorder.glucoseBatches.first)
        XCTAssertEqual(batch.map(\.glucoseLevelRaw), [140, 130, 120])
        XCTAssertNotNil(batch[1].backfilledAt)
    }

    func testUnknownCharacteristicAndUnknownOpcodeAreIgnored() {
        let transmitter = makeTransmitter(id: "8GCOV1")
        receive(transmitter, "F8083599-849E-531C-C594-30F1F86A4EA5", Data([0x4B]))
        receive(transmitter, writeControl, Data([0xEE]))
        receive(transmitter, writeControl, Data())
        receive(transmitter, writeControl, Data([0xFF]))
        receive(transmitter, writeControl, Data([0x35, 0x00, 0x00]))
        receive(transmitter, writeControl, Data([0x35, 0x00, 0x77]))
        receive(transmitter, writeControl, Data([0x29, 0x00, 0x01] + le32(1) + le32(0) + le32(2)))
        receive(transmitter, writeControl, Data([0x51, 0x00]))
        drainMain()
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
        XCTAssertTrue(recorder.sensorStatuses.isEmpty)
    }

    func testCalibrationResponseMarksQueuedCalibrationAccepted() throws {
        let coreData = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreData.mainManagedObjectContext
        let sensor = Sensor(startDate: Date().addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let accepted = calibration(bg: 120, sensor: sensor, context: context)
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        transmitter.calibrate(calibration: accepted)
        receive(transmitter, writeControl, Data([0x35, 0x00, 0x06]))
        drainMain()
        XCTAssertTrue(accepted.acceptedByTransmitter)
        let rejected = calibration(bg: 130, sensor: sensor, context: context)
        rejected.acceptedByTransmitter = true
        transmitter.calibrate(calibration: rejected)
        receive(transmitter, writeControl, Data([0x35, 0x00, 0x08]))
        drainMain()
        XCTAssertFalse(rejected.acceptedByTransmitter)
        receive(transmitter, writeControl, Data([0x35, 0x00, 0x00]))
        drainMain()
    }

    func testInvalidCalibrationsAreNotQueued() throws {
        let coreData = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreData.mainManagedObjectContext
        let sensor = Sensor(startDate: Date().addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true)
        for invalid in [calibration(bg: 30, sensor: sensor, context: context), calibration(bg: 450, sensor: sensor, context: context),
                        calibration(bg: 120, sensor: sensor, context: context, timeStamp: Date().addingTimeInterval(3600)),
                        calibration(bg: 120, sensor: sensor, context: context, timeStamp: Date().addingTimeInterval(-86_400))] {
            invalid.acceptedByTransmitter = true
            transmitter.calibrate(calibration: invalid)
            receive(transmitter, writeControl, Data([0x35, 0x00, 0x08]))
            drainMain()
            XCTAssertTrue(invalid.acceptedByTransmitter)
        }
    }

    func testSensorStartAndStopRequestsDoNotChangeKnownSession() {
        let transmitter = makeTransmitter(id: "8GCOV1", firmware: "1.6.5.25", transmitterStartDate: Date().addingTimeInterval(-10_000))
        transmitter.startSensor(sensorCode: "1234", startDate: Date())
        transmitter.startSensor(sensorCode: "5915", startDate: Date())
        transmitter.stopSensor(stopDate: Date())
        receive(transmitter, writeControl, transmitterTime(transmitterTime: 10_000, sensorCounter: 5_000))
        drainMain()
        XCTAssertEqual(recorder.transmitterStartDates.count, 1)
        XCTAssertTrue(recorder.glucoseBatches.isEmpty)
    }

    func testDiscoveredCharacteristicsDrivePrimaryProtocolWithoutConnection() {
        let transmitter = makeTransmitter(id: "8GCOV1")
        let characteristics = discover(transmitter)
        transmitter.reset(requested: true)
        for characteristic in characteristics {
            transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateNotificationStateFor: characteristic, error: nil)
        }
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateNotificationStateFor: characteristics[1], error: NSError(domain: "test", code: 1))
        let authRequest = Data([0x03]) + Data(repeating: 1, count: 16)
        receive(transmitter, receiveAuthentication, authRequest)
        receive(transmitter, receiveAuthentication, authRequest)
        receive(transmitter, receiveAuthentication, Data([0x05, 0x01, 0x01]))
        receive(transmitter, writeControl, Data([0x08, 0x01]))
        receive(transmitter, writeControl, Data([0xFF]))
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didModifyServices: [])
        drainMain()
        XCTAssertEqual(recorder.pairingRequests, 0)
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertFalse(transmitter.shouldSetNotifyValueInline())
    }

    func testDiscoveredCharacteristicsInCoexistenceOnlyObserve() throws {
        let transmitter = makeTransmitter(id: "8GCOV1", useOtherApp: true, transmitterStartDate: Date().addingTimeInterval(-100_000))
        let characteristics = discover(transmitter)
        for characteristic in characteristics {
            transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateNotificationStateFor: characteristic, error: nil)
        }
        receive(transmitter, receiveAuthentication, Data([0x03]) + Data(repeating: 1, count: 16))
        receive(transmitter, receiveAuthentication, Data([0x05, 0x01, 0x01]))
        receive(transmitter, writeControl, Data([0x4F, 0x00, 1, 0, 0, 0] + le32(99_900) + [0x96, 0x00, 0x06, 0, 0, 0]))
        receive(transmitter, writeControl, Data([0x31, 0x00] + Array(repeating: 0, count: 8) + [0x96, 0x00, 0x06, 0x00]))
        receive(transmitter, writeControl, Data([0x51, 0x00, 0x01, 0x01] + le32(99_000) + le32(100_000) + Array(repeating: 0, count: 8)))
        XCTAssertTrue(transmitter.writeDataToPeripheral(data: Data([0x01]), characteristicToWriteTo: characteristics[1], type: .withResponse))
        drainMain()
        XCTAssertEqual(recorder.sensorStatuses, ["OK / Calibrated", "OK / Calibrated"])
        XCTAssertNotNil(transmitter.scanOptions())
    }

    // MARK: - Helpers

    @discardableResult
    private func discover(_ transmitter: CGMG5Transmitter) -> [DexcomCoverageFakeCharacteristic] {
        let characteristics = ["F8083533-849E-531C-C594-30F1F86A4EA5", writeControl, receiveAuthentication, backfill, "F80835AA-849E-531C-C594-30F1F86A4EA5"]
            .map { DexcomCoverageFakeCharacteristic(uuid: $0, notifying: true) }
        let service = CBMutableService(type: CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5"), primary: true)
        service.characteristics = characteristics
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didDiscoverCharacteristicsFor: service, error: nil)
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didDiscoverCharacteristicsFor: CBMutableService(type: CBUUID(string: "180F"), primary: true), error: NSError(domain: "test", code: 1))
        return characteristics
    }

    private func calibration(bg: Double, sensor: Sensor, context: NSManagedObjectContext, timeStamp: Date = Date()) -> Calibration {
        Calibration(timeStamp: timeStamp, sensor: sensor, bg: bg, rawValue: 0, adjustedRawValue: 0, sensorConfidence: 0, rawTimeStamp: timeStamp,
                    slope: 1, intercept: 0, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 0, slopeConfidence: 0,
                    deviceName: nil, nsManagedObjectContext: context)
    }

    private func makeTransmitter(id: String, useOtherApp: Bool = false, isAnubis: Bool = false, firmware: String? = nil,
                                 transmitterStartDate: Date? = nil, batteryLastReadDate: Date? = nil) -> CGMG5Transmitter {
        let transmitter = CGMG5Transmitter(address: nil, name: nil, transmitterID: id, bluetoothTransmitterDelegate: recorder,
                                           cGMG5TransmitterDelegate: recorder, cGMTransmitterDelegate: recorder,
                                           transmitterStartDate: transmitterStartDate, sensorStartDate: nil, activeSensorStartDate: nil,
                                           calibrationToSendToTransmitter: nil, firmware: firmware, batteryLastReadDate: batteryLastReadDate,
                                           webOOPEnabled: nil, useOtherApp: useOtherApp, isAnubis: isAnubis, bluetoothSlot: .mobileApp)
        addTeardownBlock { transmitter.prepareForRelease() }
        return transmitter
    }

    private func receive(_ transmitter: CGMG5Transmitter, _ uuid: String, _ value: Data) {
        let characteristic = DexcomCoverageFakeCharacteristic(uuid: uuid, value: value)
        transmitter.peripheral(dexcomCoveragePeripheral(peripheralObject), didUpdateValueFor: characteristic, error: nil)
    }

    private func transmitterTime(transmitterTime: UInt32, sensorCounter: UInt32) -> Data {
        Data([0x25, 0x00] + le32(transmitterTime) + le32(sensorCounter))
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
}

/// Stands in for a CBPeripheral where only object identity is used by the code under test.
func dexcomCoveragePeripheral(_ object: NSObject) -> CBPeripheral {
    unsafeBitCast(object, to: CBPeripheral.self)
}

extension XCTestCase {
    func drainMain() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
}

/// Saves and restores the shared UserDefaults touched by Dexcom transmitters.
final class DexcomCoverageDefaultsSnapshot {
    private let keys: [UserDefaults.Key] = [.activeSensorStartDate, .dexcomSensorSessionIdentityData, .activeSensorTransmitterId,
                                            .timeStampOfLastBatteryReading, .activeSensorMaxSensorAgeInDaysOverridenAnubis,
                                            .previousRawGlucoseValues]
    private var values = [String: Any]()

    init() {
        for key in keys {
            values[key.rawValue] = UserDefaults.standard.object(forKey: key.rawValue)
        }
    }

    func restore() {
        for key in keys {
            UserDefaults.standard.set(values[key.rawValue], forKey: key.rawValue)
        }
    }
}

final class DexcomCoverageRecorder: CGMTransmitterDelegate, BluetoothTransmitterDelegate, CGMG5TransmitterDelegate, CGMG7TransmitterDelegate {
    var glucoseBatches = [[GlucoseData]]()
    var cgmBatteryInfos = [TransmitterBatteryInfo]()
    var sensorAges = [TimeInterval]()
    var newSensorDates = [Date?]()
    var stopCount = 0
    var notDetectedCount = 0
    var errors = [String]()
    var healthEvents = [CGMSensorHealthEvent]()
    var startResults = [CGMSensorSessionStartResult]()
    var confirmedSessions = [Date]()
    var calibrationStates = [(DexcomAlgorithmState, Date)]()
    var pairingRequests = 0
    var pairedCount = 0
    var firmwares = [String]()
    var batteryInfos = [TransmitterBatteryInfo]()
    var transmitterStartDates = [Date]()
    var resets = [Bool]()
    var sensorStartDates = [Date?]()
    var sensorStatuses = [String?]()
    var anubisReports = [Bool]()
    var sessionLengths = [TimeInterval]()
    var versions = [DexcomG7VersionMessage]()
    var g7Batteries = [(DexcomG7BatteryStatusMessage, Bool)]()

    func newSensorDetected(sensorStartDate: Date?) { newSensorDates.append(sensorStartDate) }
    func sensorStopDetected() { stopCount += 1 }
    func sensorNotDetected() { notDetectedCount += 1 }
    func cgmTransmitterInfoReceived(glucoseData: inout [GlucoseData], transmitterBatteryInfo: TransmitterBatteryInfo?, sensorAge: TimeInterval?) {
        if !glucoseData.isEmpty { glucoseBatches.append(glucoseData) }
        if let transmitterBatteryInfo { cgmBatteryInfos.append(transmitterBatteryInfo) }
        if let sensorAge { sensorAges.append(sensorAge) }
    }
    func errorOccurred(xDripError: XdripError) { errors.append(xDripError.errorDescription ?? "") }
    func sensorHealthEventOccurred(_ event: CGMSensorHealthEvent) { healthEvents.append(event) }
    func sensorSessionStartResultReceived(_ result: CGMSensorSessionStartResult) { startResults.append(result) }
    func sensorSessionConfirmed(startDate: Date) { confirmedSessions.append(startDate) }
    func dexcomG6CalibrationStateReceived(_ state: DexcomAlgorithmState, sensorStartDate: Date, from transmitter: CGMG5Transmitter) {
        calibrationStates.append((state, sensorStartDate))
    }

    func didConnectTo(bluetoothTransmitter: BluetoothTransmitter) {}
    func didDisconnectFrom(bluetoothTransmitter: BluetoothTransmitter) {}
    func deviceDidUpdateBluetoothState(state: CBManagerState, bluetoothTransmitter: BluetoothTransmitter) {}
    func transmitterNeedsPairing(bluetoothTransmitter: BluetoothTransmitter) { pairingRequests += 1 }
    func successfullyPaired() { pairedCount += 1 }
    func pairingFailed() {}
    func error(message: String) { errors.append(message) }
    func heartBeat() {}

    func received(firmware: String, cGMG5Transmitter: CGMG5Transmitter) { firmwares.append(firmware) }
    func received(transmitterBatteryInfo: TransmitterBatteryInfo, cGMG5Transmitter: CGMG5Transmitter) { batteryInfos.append(transmitterBatteryInfo) }
    func received(transmitterStartDate: Date, cGMG5Transmitter: CGMG5Transmitter) { transmitterStartDates.append(transmitterStartDate) }
    func reset(for cGMG5Transmitter: CGMG5Transmitter, successful: Bool) { resets.append(successful) }
    func received(sensorStartDate: Date?, cGMG5Transmitter: CGMG5Transmitter) { sensorStartDates.append(sensorStartDate) }
    func received(sensorStatus: String?, cGMG5Transmitter: CGMG5Transmitter) { sensorStatuses.append(sensorStatus) }
    func received(isAnubis: Bool, cGMG5Transmitter: CGMG5Transmitter) { anubisReports.append(isAnubis) }

    func received(sensorStartDate: Date?, cGMG7Transmitter: CGMG7Transmitter) { sensorStartDates.append(sensorStartDate) }
    func received(sensorStatus: String?, cGMG7Transmitter: CGMG7Transmitter) { sensorStatuses.append(sensorStatus) }
    func received(sensorSessionLength: TimeInterval, cGMG7Transmitter: CGMG7Transmitter) { sessionLengths.append(sensorSessionLength) }
    func received(version: DexcomG7VersionMessage, cGMG7Transmitter: CGMG7Transmitter) { versions.append(version) }
    func received(battery: DexcomG7BatteryStatusMessage, readAt: Date, isFirstReading: Bool, cGMG7Transmitter: CGMG7Transmitter) {
        g7Batteries.append((battery, isFirstReading))
    }
}
