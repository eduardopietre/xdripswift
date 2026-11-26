//
//  DexcomTestSupport.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import CoreData
import XCTest
@testable import xdrip

// Test doubles and helpers shared by the Dexcom and Bluetooth transmitter test suites.

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

/// A characteristic whose value and notification state the tests can set.
final class DexcomCoverageFakeCharacteristic: CBMutableCharacteristic {
    var notifying: Bool
    var fakeValue: Data?

    override var isNotifying: Bool { notifying }
    override var value: Data? {
        get { fakeValue }
        set { fakeValue = newValue }
    }

    init(uuid: String, notifying: Bool = false, value: Data? = nil) {
        self.notifying = notifying
        super.init(type: CBUUID(string: uuid), properties: [.notify, .write, .writeWithoutResponse, .read], value: nil, permissions: [.writeable])
        fakeValue = value
    }
}
