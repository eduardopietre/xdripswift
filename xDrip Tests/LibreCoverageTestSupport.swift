//
//  LibreCoverageTestSupport.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import XCTest
@testable import xdrip

/// Saves and restores the Libre related UserDefaults keys touched by the parsers and transmitters.
final class LibreCoverageDefaultsSnapshot {
    static let libreKeys: [UserDefaults.Key] = [
        .previousRawLibreValues, .previousRawGlucoseValues, .previousRawTemperatureValues,
        .previousTemperatureAdjustmentValues, .libre1DerivedAlgorithmParameters, .libreSensorUID,
        .librePatchInfo, .libreActiveSensorUnlockCode, .libreActiveSensorUnlockCount,
        .nfcScanSuccessful, .nfcScanFailed,
    ]

    private let keys: [String]
    private var values: [String: Any] = [:]

    init(extraKeys: [String] = []) {
        keys = Self.libreKeys.map(\.rawValue) + extraKeys
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { values[key] = value }
        }
    }

    func clear() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func restore() {
        for key in keys {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

final class LibreCoverageCGMDelegateSpy: CGMTransmitterDelegate {
    var newSensorDates: [Date?] = []
    var sensorStopCount = 0
    var sensorNotDetectedCount = 0
    var receivedGlucose: [[GlucoseData]] = []
    var receivedBattery: [TransmitterBatteryInfo?] = []
    var receivedSensorAges: [TimeInterval?] = []
    var errors: [XdripError] = []
    var healthEvents: [CGMSensorHealthEvent] = []

    func newSensorDetected(sensorStartDate: Date?) { newSensorDates.append(sensorStartDate) }
    func sensorStopDetected() { sensorStopCount += 1 }
    func sensorNotDetected() { sensorNotDetectedCount += 1 }
    func cgmTransmitterInfoReceived(glucoseData: inout [GlucoseData], transmitterBatteryInfo: TransmitterBatteryInfo?, sensorAge: TimeInterval?) {
        receivedGlucose.append(glucoseData)
        receivedBattery.append(transmitterBatteryInfo)
        receivedSensorAges.append(sensorAge)
    }
    func errorOccurred(xDripError: XdripError) { errors.append(xDripError) }
    func sensorHealthEventOccurred(_ event: CGMSensorHealthEvent) { healthEvents.append(event) }
}

final class LibreCoverageBluetoothDelegateStub: BluetoothTransmitterDelegate {
    var errorMessages: [String] = []
    func didConnectTo(bluetoothTransmitter: BluetoothTransmitter) {}
    func didDisconnectFrom(bluetoothTransmitter: BluetoothTransmitter) {}
    func deviceDidUpdateBluetoothState(state: CBManagerState, bluetoothTransmitter: BluetoothTransmitter) {}
    func transmitterNeedsPairing(bluetoothTransmitter: BluetoothTransmitter) {}
    func successfullyPaired() {}
    func pairingFailed() {}
    func error(message: String) { errorMessages.append(message) }
    func heartBeat() {}
}

enum LibreCoverageBytes {
    /// Libre FRAM CRC: reflected CCITT with seed 0xFFFF, bit reversed and byte swapped, stored big endian.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        var reversed: UInt16 = 0
        for _ in 0..<16 {
            reversed = reversed << 1 | crc & 1
            crc >>= 1
        }
        return reversed.byteSwapped
    }

    static func applyCRC(_ data: inout [UInt8], range: Range<Int>) {
        let crc = crc16(Array(data[(range.lowerBound + 2)..<range.upperBound]))
        data[range.lowerBound] = UInt8(crc >> 8)
        data[range.lowerBound + 1] = UInt8(crc & 0xFF)
    }

    static func data(hex: String) -> Data {
        Data(hexadecimalString: hex)!
    }
}

/// Builds a 344 byte Libre 1 FRAM image with consistent CRCs.
struct LibreCoverageFRAM {
    var state: UInt8 = 0x03
    var sensorMinutes: Int = 1000
    var trendIndex: Int = 0
    var historyIndex: Int = 0
    /// most recent first
    var trend: [Int] = Array(repeating: 100, count: 16)
    /// most recent first
    var history: [Int] = Array(repeating: 100, count: 32)
    var rawTemperature: Int = 7000
    /// calibration bytes: i2 must be at least 1 for the local algorithm
    var calibrationI2: Int = 1
    var footerCalibration: [UInt8] = [0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x60, 0x01]

    func bytes() -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 344)
        data[4] = state
        data[2] = UInt8((calibrationI2 << 3) & 0xFF)
        data[3] = UInt8((calibrationI2 >> 5) & 0xFF)
        data[26] = UInt8(trendIndex)
        data[27] = UInt8(historyIndex)
        for (k, value) in trend.enumerated() {
            var slot = trendIndex - k - 1
            if slot < 0 { slot += 16 }
            write(&data, offset: 28 + slot * 6, raw: value)
        }
        for (k, value) in history.enumerated() {
            var slot = historyIndex - k - 1
            if slot < 0 { slot += 32 }
            write(&data, offset: 124 + slot * 6, raw: value)
        }
        data[316] = UInt8(sensorMinutes & 0xFF)
        data[317] = UInt8((sensorMinutes >> 8) & 0xFF)
        for (i, byte) in footerCalibration.enumerated() { data[336 + i] = byte }
        LibreCoverageBytes.applyCRC(&data, range: 0..<24)
        LibreCoverageBytes.applyCRC(&data, range: 24..<320)
        LibreCoverageBytes.applyCRC(&data, range: 320..<344)
        return data
    }

    func data() -> Data { Data(bytes()) }

    private func write(_ data: inout [UInt8], offset: Int, raw: Int) {
        data[offset] = UInt8(raw & 0xFF)
        data[offset + 1] = UInt8((raw >> 8) & 0x1F)
        data[offset + 3] = UInt8(rawTemperature & 0xFF)
        data[offset + 4] = UInt8((rawTemperature >> 8) & 0x3F)
    }
}

/// Real captures embedded in the production test helpers of the MiaoMiao and Libre 2 transmitters.
enum LibreCoverageSamples {
    static let miaoMiaoUID = "3f38a50000a407e0"
    static let miaoMiaoPatchInfo = "9D083001FB30"
    static let miaoMiaoEncryptedFRAM =
        "3244c69c763a7ec4290d1deb4db5cab2" + "5711a23c3cd3e7e27950a87afe243567" + "360a26adb3e6cf1754787603df0d6a57"
        + "aff41ec028efd297b067da06878cd7a6" + "6bff7a7121fe4072e74410be0d64b760" + "4e7c1ded16a24d14307f740fff7417b5"
        + "2fc31cfcf3976541c811cf4622f855a5" + "3589133584bee671a9aac8572bc97dfc" + "00966f04dc138780d26f301f8ed4ea10"
        + "36d358ece134a4142470ab29d695afe1" + "9be43c297f278039b8d483477d65b487" + "1786be196d0e48252488e8764a790089"
        + "78ad4e0466976eec5f06896673092de2" + "29925d7fdb67453a3011437a931c0b67" + "978157248da2fec758ff817aee394d84"
        + "00f3e645bfd9ec271fec5581b9f0e976" + "5d758d941fca99a3fa5c645e5c66bd7a" + "537cfa0a46a9471a5f7e00876f7640ba"
        + "32af681c01936f5bd511e0a672eb5fab" + "a48967e9d4bd017fb4aebcb7fbca765e" + "48d5e4e1a7a2665f200eff8b47b60d1a"
        + "5870ccdc6cb29783"

    static let libre2UID = "e3a18e0100a407e0"
    static let libre2Frames = [
        "ebb86eb952942ce055278df46b68ba1eacd3c78c7e800ea3890c61116679c2a3fcc220a95571ff760207682942f0",
        "38a5b8062dcaf18c537a7cd030cfe3e0c0c896e65131fc4ac0f51b78d496d2964f8f1971e71bca45bcd8bfcc1450",
        "5fdf6254dff6862d9b8abb82e7212a83fddc6f94d42366808b988f3fd138b7afcfe9a7a043fa899253256186992d",
        "473791584eed0ae7fc9323f466f1a04b19e45940c626422bcbe817da8f5e9097cb1806f91c8b32f802b60a098eec",
        "51e838b9189f16883f930f52893c24b95cb01bde99c49201baae2d9e7298a18efdeec1a19149638982f156f1749d",
        "2575a8743b612c83359a8bc21327202113bf606118ad6e9529b6f3803da475134e17a59010ba897a3e8615dbc154",
    ]
}
