//
//  LibreCoverageTransmitterTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import XCTest
@testable import xdrip

private final class Libre2DelegateSpy: CGMLibre2TransmitterDelegate {
    var serialNumbers: [String] = []
    var sensorTimes: [Int] = []
    func received(serialNumber: String, from cGMLibre2Transmitter: CGMLibre2Transmitter) { serialNumbers.append(serialNumber) }
    func received(sensorTimeInMinutes: Int, from cGMLibre2Transmitter: CGMLibre2Transmitter) { sensorTimes.append(sensorTimeInMinutes) }
}

private final class MiaoMiaoDelegateStub: CGMMiaoMiaoTransmitterDelegate {
    func received(firmware: String, from cGMMiaoMiaoTransmitter: CGMMiaoMiaoTransmitter) {}
    func received(hardware: String, from cGMMiaoMiaoTransmitter: CGMMiaoMiaoTransmitter) {}
    func received(serialNumber: String, from cGMMiaoMiaoTransmitter: CGMMiaoMiaoTransmitter) {}
    func received(batteryLevel: Int, from cGMMiaoMiaoTransmitter: CGMMiaoMiaoTransmitter) {}
    func received(libreSensorType: LibreSensorType, from cGMMiaoMiaoTransmitter: CGMMiaoMiaoTransmitter) {}
    func received(sensorStatus: LibreSensorState, from cGMMiaoMiaoTransmitter: CGMMiaoMiaoTransmitter) {}
}

private final class BubbleDelegateStub: CGMBubbleTransmitterDelegate {
    func received(firmware: String, from cGMBubbleTransmitter: CGMBubbleTransmitter) {}
    func received(hardware: String, from cGMBubbleTransmitter: CGMBubbleTransmitter) {}
    func received(serialNumber: String, from cGMBubbleTransmitter: CGMBubbleTransmitter) {}
    func received(batteryLevel: Int, from cGMBubbleTransmitter: CGMBubbleTransmitter) {}
    func received(libreSensorType: LibreSensorType, from cGMBubbleTransmitter: CGMBubbleTransmitter) {}
    func received(sensorStatus: LibreSensorState, from cGMBubbleTransmitter: CGMBubbleTransmitter) {}
}

private final class Libre3DelegateSpy: CGMLibre3TransmitterDelegate {
    var records: [Libre3PairingRecord] = []
    func libre3Transmitter(_ transmitter: CGMLibre3Transmitter, updated record: Libre3PairingRecord) { records.append(record) }
}

final class LibreCoverageTransmitterTests: XCTestCase {
    private static let bubbleDateKey = "CGMBubbleTransmitterLastGlucoseDate"
    private var snapshot: LibreCoverageDefaultsSnapshot!
    private let bluetoothDelegate = LibreCoverageBluetoothDelegateStub()
    private let cgmDelegate = LibreCoverageCGMDelegateSpy()
    private let libre2Delegate = Libre2DelegateSpy()
    private let miaoMiaoDelegate = MiaoMiaoDelegateStub()
    private let bubbleDelegate = BubbleDelegateStub()
    private let libre3Delegate = Libre3DelegateSpy()
    private var transmitters: [BluetoothTransmitter] = []

    override func setUp() {
        super.setUp()
        snapshot = LibreCoverageDefaultsSnapshot(extraKeys: [Self.bubbleDateKey])
        snapshot.clear()
    }

    override func tearDown() {
        transmitters.forEach { $0.prepareForRelease() }
        transmitters.removeAll()
        drainMainQueue()
        snapshot.restore()
        super.tearDown()
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    private func makeLibre2(serial: String? = nil, webOOP: Bool? = nil, nonFixed: Bool? = nil, address: String? = nil) -> CGMLibre2Transmitter {
        let transmitter = CGMLibre2Transmitter(address: address, name: nil, bluetoothTransmitterDelegate: bluetoothDelegate, cGMLibre2TransmitterDelegate: libre2Delegate, sensorSerialNumber: serial, cGMTransmitterDelegate: cgmDelegate, nonFixedSlopeEnabled: nonFixed, webOOPEnabled: webOOP)
        transmitters.append(transmitter)
        return transmitter
    }

    private func feed(_ transmitter: CGMLibre2Transmitter, frame: Data, uid: Data) {
        transmitter.processValue(value: frame.prefix(20), sensorUID: uid)
        transmitter.processValue(value: frame.dropFirst(20).prefix(20), sensorUID: uid)
        transmitter.processValue(value: frame.dropFirst(40), sensorUID: uid)
    }

    // MARK: - CGMLibre2Transmitter configuration

    func testLibre2DefaultsAndIdentifiers() {
        let transmitter = makeLibre2()
        XCTAssertEqual(transmitter.cgmTransmitterType(), .Libre2)
        XCTAssertFalse(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.isNonFixedSlopeEnabled())
        XCTAssertEqual(transmitter.getCBUUID_Service(), "FDE3")
        XCTAssertEqual(transmitter.getCBUUID_Receive(), "F002")
        XCTAssertNil(transmitter.maxSensorAgeInDays(), "unknown until the sensor type is read via NFC")
    }

    func testLibre2SettingsCanBeToggled() {
        let transmitter = makeLibre2(webOOP: true, nonFixed: true, address: UUID().uuidString)
        XCTAssertTrue(transmitter.isWebOOPEnabled())
        XCTAssertTrue(transmitter.isNonFixedSlopeEnabled())
        transmitter.setWebOOPEnabled(enabled: false)
        transmitter.setNonFixedSlopeEnabled(enabled: false)
        XCTAssertFalse(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.isNonFixedSlopeEnabled())
        transmitter.setWebOOPEnabled(enabled: false)
        XCTAssertFalse(transmitter.isWebOOPEnabled())
    }

    // MARK: - CGMLibre2Transmitter NFC delegate

    func testReceivingNewSensorUIDStoresItAndAnnouncesTheSerial() {
        let transmitter = makeLibre2()
        let uid = LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID)
        let patchInfo = LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo)
        transmitter.received(sensorUID: uid, patchInfo: patchInfo)
        drainMainQueue()
        XCTAssertEqual(UserDefaults.standard.libreSensorUID, uid)
        XCTAssertEqual(UserDefaults.standard.librePatchInfo, patchInfo)
        XCTAssertEqual(libre2Delegate.serialNumbers, ["3MH0033N1WD"])
        XCTAssertEqual(cgmDelegate.newSensorDates.count, 1)
    }

    func testReceivingKnownSensorUIDDoesNotAnnounceANewSensor() {
        let transmitter = makeLibre2(serial: "3MH0033N1WD")
        transmitter.received(sensorUID: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID), patchInfo: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo))
        drainMainQueue()
        XCTAssertTrue(libre2Delegate.serialNumbers.isEmpty)
        XCTAssertTrue(cgmDelegate.newSensorDates.isEmpty)
    }

    func testInvalidSensorUIDStillStoresPatchInfo() {
        let transmitter = makeLibre2()
        transmitter.received(sensorUID: Data([1, 2, 3]), patchInfo: Data([0x9D, 1]))
        drainMainQueue()
        XCTAssertTrue(libre2Delegate.serialNumbers.isEmpty)
        XCTAssertEqual(UserDefaults.standard.librePatchInfo, Data([0x9D, 1]))
    }

    func testReceivingEncryptedFRAMStoresDerivedParameters() throws {
        let transmitter = makeLibre2()
        transmitter.received(sensorUID: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID), patchInfo: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo))
        transmitter.received(fram: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoEncryptedFRAM))
        let parameters = try XCTUnwrap(UserDefaults.standard.libre1DerivedAlgorithmParameters)
        XCTAssertEqual(parameters.serialNumber, "3MH00199R7W")
        XCTAssertEqual(parameters.slope_slope, 1.35e-05, accuracy: 1e-12)
        XCTAssertEqual(transmitter.maxSensorAgeInDays(), 14.5)
    }

    func testFRAMWithoutKnownSerialIsIgnored() {
        let transmitter = makeLibre2()
        UserDefaults.standard.libreSensorUID = LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID)
        UserDefaults.standard.librePatchInfo = LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo)
        transmitter.received(fram: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoEncryptedFRAM))
        XCTAssertNil(UserDefaults.standard.libre1DerivedAlgorithmParameters)
        XCTAssertNil(transmitter.maxSensorAgeInDays())
    }

    func testFRAMOfUnencryptedSensorTypeDoesNotDeriveParameters() {
        let transmitter = makeLibre2(serial: "0ABC")
        UserDefaults.standard.libreSensorUID = Data(repeating: 0, count: 8)
        UserDefaults.standard.librePatchInfo = Data([0xDF, 0, 0, 0, 0, 0])
        transmitter.received(fram: LibreCoverageFRAM().data())
        XCTAssertNil(UserDefaults.standard.libre1DerivedAlgorithmParameters)
        XCTAssertEqual(transmitter.maxSensorAgeInDays(), 14.5)
    }

    func testStreamingEnabledResetsUnlockCountOnlyOnSuccess() {
        let transmitter = makeLibre2()
        UserDefaults.standard.libreActiveSensorUnlockCount = 7
        transmitter.streamingEnabled(successful: false)
        XCTAssertEqual(UserDefaults.standard.libreActiveSensorUnlockCount, 7)
        transmitter.streamingEnabled(successful: true)
        XCTAssertEqual(UserDefaults.standard.libreActiveSensorUnlockCount, 0)
    }

    func testSuccessfulNFCScanSetsSuccessFlag() {
        let transmitter = makeLibre2()
        transmitter.nfcScanResult(.succeeded)
        XCTAssertTrue(UserDefaults.standard.nfcScanSuccessful)
        XCTAssertFalse(UserDefaults.standard.nfcScanFailed)
        transmitter.nfcScanResult(.succeeded)
        XCTAssertTrue(UserDefaults.standard.nfcScanSuccessful)
    }

    func testEveryUnsuccessfulNFCOutcomeSetsFailureFlag() {
        let transmitter = makeLibre2()
        for result: LibreNFCScanResult in [.failed, .cancelled, .timedOut] {
            UserDefaults.standard.nfcScanFailed = false
            transmitter.nfcScanResult(result)
            XCTAssertTrue(UserDefaults.standard.nfcScanFailed, "\(result)")
            transmitter.nfcScanResult(result)
            XCTAssertTrue(UserDefaults.standard.nfcScanFailed)
        }
        XCTAssertFalse(UserDefaults.standard.nfcScanSuccessful)
    }

    func testTestRangeSchedulesAReplayTimer() {
        let transmitter = makeLibre2()
        transmitter.testRange()
        XCTAssertNotNil(transmitter.repeatingTimer)
        XCTAssertNil(UserDefaults.standard.previousRawGlucoseValues)
        transmitter.repeatingTimer = nil
        XCTAssertNil(transmitter.repeatingTimer)
    }

    // MARK: - CGMLibre2Transmitter BLE frames

    func testCompleteFrameIsDecryptedParsedAndDelivered() {
        let transmitter = makeLibre2(serial: "3MH0033N1WD")
        let before = Date()
        feed(transmitter, frame: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[0]), uid: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID))
        drainMainQueue()
        XCTAssertEqual(libre2Delegate.sensorTimes, [795])
        XCTAssertEqual(cgmDelegate.receivedSensorAges, [795 * 60])
        let glucose = cgmDelegate.receivedGlucose.first ?? []
        XCTAssertEqual(glucose.count, 10)
        XCTAssertGreaterThanOrEqual(glucose.first?.timeStamp ?? .distantPast, before)
        XCTAssertEqual(UserDefaults.standard.previousRawGlucoseValues?.first, 648)
    }

    func testConsecutiveFramesAreProcessedIndependently() {
        let transmitter = makeLibre2(serial: "3MH0033N1WD")
        let uid = LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID)
        for index in [0, 2, 3] {
            feed(transmitter, frame: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[index]), uid: uid)
        }
        drainMainQueue()
        XCTAssertEqual(libre2Delegate.sensorTimes, [795, 797, 798])
        XCTAssertEqual(cgmDelegate.receivedGlucose.count, 3)
    }

    func testIncompleteFrameIsNotDelivered() {
        let transmitter = makeLibre2()
        transmitter.processValue(value: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[0]).prefix(30), sensorUID: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID))
        drainMainQueue()
        XCTAssertTrue(cgmDelegate.receivedGlucose.isEmpty)
    }

    func testOversizedFrameIsDiscarded() {
        let transmitter = makeLibre2()
        let oversized = LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[0]) + Data([0, 0, 0, 0])
        transmitter.processValue(value: oversized, sensorUID: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID))
        drainMainQueue()
        XCTAssertTrue(cgmDelegate.receivedGlucose.isEmpty)
        XCTAssertTrue(libre2Delegate.sensorTimes.isEmpty)
    }

    func testFrameFromAnotherSensorFailsDecryption() {
        let transmitter = makeLibre2()
        feed(transmitter, frame: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[0]), uid: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID))
        drainMainQueue()
        XCTAssertTrue(cgmDelegate.receivedGlucose.isEmpty)
    }

    func testWebOOPWithoutMatchingParametersSkipsDelivery() {
        let transmitter = makeLibre2(serial: "3MH0033N1WD", webOOP: true)
        UserDefaults.standard.libre1DerivedAlgorithmParameters = Libre1DerivedAlgorithmParameters(slope_slope: 0, slope_offset: 0, offset_slope: 1, offset_offset: 0, isValidForFooterWithReverseCRCs: 0, extraSlope: 1, extraOffset: 0, sensorSerialNumber: "OTHER")
        feed(transmitter, frame: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[0]), uid: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID))
        drainMainQueue()
        XCTAssertTrue(cgmDelegate.receivedGlucose.isEmpty)
        XCTAssertTrue(libre2Delegate.sensorTimes.isEmpty)
    }

    func testWebOOPWithMatchingParametersUsesThem() {
        let transmitter = makeLibre2(serial: "3MH0033N1WD", webOOP: true)
        UserDefaults.standard.libre1DerivedAlgorithmParameters = Libre1DerivedAlgorithmParameters(slope_slope: 0, slope_offset: 0, offset_slope: 0.1, offset_offset: 0, isValidForFooterWithReverseCRCs: 0, extraSlope: 1, extraOffset: 0, sensorSerialNumber: "3MH0033N1WD")
        feed(transmitter, frame: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[0]), uid: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID))
        drainMainQueue()
        XCTAssertEqual(cgmDelegate.receivedGlucose.first?.first?.glucoseLevelRaw ?? 0, 64.8, accuracy: 1e-9)
    }

    // MARK: - CGMMiaoMiaoTransmitter

    func testMiaoMiaoConfigurationWithoutPeripheral() {
        let transmitter = CGMMiaoMiaoTransmitter(address: nil, name: nil, bluetoothTransmitterDelegate: bluetoothDelegate, cGMMiaoMiaoTransmitterDelegate: miaoMiaoDelegate, cGMTransmitterDelegate: cgmDelegate, sensorSerialNumber: nil, webOOPEnabled: nil, nonFixedSlopeEnabled: nil)
        transmitters.append(transmitter)
        XCTAssertEqual(transmitter.cgmTransmitterType(), .miaomiao)
        XCTAssertEqual(transmitter.getCBUUID_Service(), "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        XCTAssertEqual(transmitter.getCBUUID_Receive(), "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        XCTAssertNil(transmitter.maxSensorAgeInDays())
        XCTAssertFalse(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.isNonFixedSlopeEnabled())
        XCTAssertFalse(transmitter.sendStartReadingCommand(), "no peripheral to write to")
    }

    func testMiaoMiaoSettingChangesAreKeptEvenWithoutConnection() {
        let transmitter = CGMMiaoMiaoTransmitter(address: UUID().uuidString, name: "MiaoMiao", bluetoothTransmitterDelegate: bluetoothDelegate, cGMMiaoMiaoTransmitterDelegate: miaoMiaoDelegate, cGMTransmitterDelegate: cgmDelegate, sensorSerialNumber: "0ABC", webOOPEnabled: true, nonFixedSlopeEnabled: true)
        transmitters.append(transmitter)
        XCTAssertTrue(transmitter.isWebOOPEnabled())
        XCTAssertTrue(transmitter.isNonFixedSlopeEnabled())
        transmitter.setWebOOPEnabled(enabled: false)
        transmitter.setNonFixedSlopeEnabled(enabled: false)
        transmitter.requestNewReading()
        XCTAssertFalse(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.isNonFixedSlopeEnabled())
    }

    // MARK: - CGMBubbleTransmitter

    private func makeBubble() -> CGMBubbleTransmitter {
        let transmitter = CGMBubbleTransmitter(address: nil, name: nil, bluetoothTransmitterDelegate: bluetoothDelegate, cGMBubbleTransmitterDelegate: bubbleDelegate, cGMTransmitterDelegate: cgmDelegate, sensorSerialNumber: nil, webOOPEnabled: nil, nonFixedSlopeEnabled: nil)
        transmitters.append(transmitter)
        return transmitter
    }

    func testBubbleConfigurationWithoutPeripheral() {
        let transmitter = makeBubble()
        XCTAssertEqual(transmitter.cgmTransmitterType(), .Bubble)
        XCTAssertEqual(transmitter.getCBUUID_Service(), "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        XCTAssertEqual(transmitter.getCBUUID_Receive(), "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        XCTAssertNil(transmitter.maxSensorAgeInDays())
        XCTAssertFalse(transmitter.sendStartReadingCommmand())
        transmitter.setWebOOPEnabled(enabled: true)
        transmitter.setNonFixedSlopeEnabled(enabled: true)
        transmitter.requestNewReading()
        XCTAssertTrue(transmitter.isWebOOPEnabled())
        XCTAssertTrue(transmitter.isNonFixedSlopeEnabled())
    }

    func testBubbleReadIntervalDefaultsToFiveMinutes() {
        XCTAssertEqual(makeBubble().nextReadTimeinterval(), 5)
    }

    func testBubbleReadIntervalFollowsTheLastGlucoseWithinOneToFiveMinutes() {
        let transmitter = makeBubble()
        UserDefaults.standard.set(Date().addingTimeInterval(-3.5 * 60), forKey: Self.bubbleDateKey)
        XCTAssertEqual(transmitter.nextReadTimeinterval(), 3)
        UserDefaults.standard.set(Date().addingTimeInterval(-1.2 * 60), forKey: Self.bubbleDateKey)
        XCTAssertEqual(transmitter.nextReadTimeinterval(), 1)
    }

    func testBubbleReadIntervalFallsBackOutsideOneToFiveMinutes() {
        let transmitter = makeBubble()
        UserDefaults.standard.set(Date().addingTimeInterval(-30), forKey: Self.bubbleDateKey)
        XCTAssertEqual(transmitter.nextReadTimeinterval(), 5)
        UserDefaults.standard.set(Date().addingTimeInterval(-20 * 60), forKey: Self.bubbleDateKey)
        XCTAssertEqual(transmitter.nextReadTimeinterval(), 5)
    }

    // MARK: - CGMLibre3Transmitter

    private func makeLibre3(_ record: Libre3PairingRecord) -> CGMLibre3Transmitter {
        let transmitter = CGMLibre3Transmitter(address: nil, name: nil, record: record, bluetoothTransmitterDelegate: bluetoothDelegate, libreDelegate: libre3Delegate, cgmDelegate: cgmDelegate)
        transmitters.append(transmitter)
        return transmitter
    }

    private func readyRecord(wearMinutes: Int = 20160) -> Libre3PairingRecord {
        var record = Libre3PairingRecord.unavailable(serial: "LIBRE3TEST")
        record.nfcCompleted = true
        record.blePIN = Data([1, 2, 3, 4])
        record.cryptoVersion = 1
        record.wearMinutes = wearMinutes
        return record
    }

    func testLibre3WithoutNFCPairingNeedsAScanAndShowsRecovery() {
        let transmitter = makeLibre3(.unavailable(serial: "ABC"))
        XCTAssertEqual(transmitter.startScanning(), .nfcScanNeeded)
        XCTAssertFalse(transmitter.isAuthenticated)
        XCTAssertNil(transmitter.sensorStatus)
        XCTAssertEqual(transmitter.connectionDescription, TextsLibre3.localized(Libre3ConnectionError.recovery.localizedDescription))
        XCTAssertEqual(transmitter.sensorSerial, "ABC")
    }

    func testLibre3NeedsPINAndCurrentCryptoVersionBeforeScanning() {
        var missingPIN = readyRecord()
        missingPIN.blePIN = nil
        XCTAssertEqual(makeLibre3(missingPIN).startScanning(), .nfcScanNeeded)
        var shortPIN = readyRecord()
        shortPIN.blePIN = Data([1, 2])
        XCTAssertEqual(makeLibre3(shortPIN).startScanning(), .nfcScanNeeded)
        var legacy = readyRecord()
        legacy.cryptoVersion = nil
        XCTAssertEqual(makeLibre3(legacy).startScanning(), .nfcScanNeeded)
    }

    func testLibre3ReadyRecordWaitsForSensor() {
        let transmitter = makeLibre3(readyRecord())
        XCTAssertNotEqual(transmitter.startScanning(), .nfcScanNeeded)
        XCTAssertEqual(transmitter.sensorStatus, .waitingForSensor)
        XCTAssertEqual(transmitter.connectionDescription, TextsLibre3.localized("Waiting for sensor"))
    }

    func testLibre3ProductInformationFollowsTheRecord() {
        let libre3 = makeLibre3(readyRecord())
        XCTAssertEqual(libre3.cgmTransmitterType(), .Libre3)
        XCTAssertEqual(libre3.productName, "Libre 3")
        XCTAssertEqual(libre3.maxSensorAgeInDays(), 14)
        XCTAssertEqual(libre3.sensorWarmupDurationInMinutes(), 60)
        XCTAssertTrue(libre3.isWebOOPEnabled())
        XCTAssertFalse(libre3.nonWebOOPAllowed())
        XCTAssertEqual(libre3.getCBUUID_Service(), Libre3LibreSensorGATT.serviceUUID.uuidString)
        XCTAssertEqual(libre3.getCBUUID_Receive(), Libre3LibreSensorGATT.Char.glucoseData.uuidString)
        let plus = makeLibre3(readyRecord(wearMinutes: 15 * 1440))
        XCTAssertEqual(plus.productName, "Libre 3 Plus")
        XCTAssertEqual(plus.maxSensorAgeInDays(), 15)
    }

    // MARK: - Libre3HeartBeatBluetoothTransmitter

    func testHeartbeatStartsWithoutBatteryLevel() {
        let heartbeat = Libre3HeartBeatBluetoothTransmitter(address: nil, name: nil, transmitterID: "ABBOTT", bluetoothTransmitterDelegate: bluetoothDelegate)
        transmitters.append(heartbeat)
        XCTAssertNil(heartbeat.batteryLevel)
        heartbeat.updateBatteryLevel()
        XCTAssertNil(heartbeat.batteryLevel, "no battery characteristic was discovered")
    }

    func testHeartbeatRestorationWithoutPeripheralKeepsState() {
        let heartbeat = Libre3HeartBeatBluetoothTransmitter(address: UUID().uuidString, name: "x", transmitterID: "ABB", bluetoothTransmitterDelegate: bluetoothDelegate)
        transmitters.append(heartbeat)
        let central = CBCentralManager(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        heartbeat.centralManager(central, willRestoreState: [:])
        XCTAssertNil(heartbeat.batteryLevel)
        XCTAssertNil(heartbeat.deviceName)
    }
}
