//
//  LibreRawMeasurementTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Checks the decoding of Libre raw data into glucose: the 6 byte FRAM measurement records, the
/// factory calibration bit fields and the local (temperature compensated) algorithm, plus the
/// parameters derived from it that xDrip caches per sensor.
///
/// These values are read from bit fields that cross byte boundaries; one wrong shift or mask turns
/// a plausible glucose value into a wrong one without any error. Bytes are built by hand from the
/// documented layout so the decoder is not used to produce its own expectations.
final class LibreRawMeasurementTests: XCTestCase {

    // MARK: - fixtures

    /// Calibration of a real Libre 2 sensor (i2 794, i3 18, i4 6753, i5 10632, i6 7132).
    private static func realisticCalibration() -> LibreCalibrationInfo {
        var info = LibreCalibrationInfo(bytes: Data(count: 344), libreSensorType: .libre1)
        info.i1 = 0
        info.i2 = 794
        info.i3 = 18
        info.i4 = 6753
        info.i5 = 10632
        info.i6 = 7132
        return info
    }

    /// FRAM bytes holding that calibration, written byte by byte from the Libre 1 layout:
    /// - byte 2 bits 0-2: i1; byte 2 bits 3-7 and byte 3 bits 0-4: i2 (10 bits)
    /// - byte 0x150: i3, its sign in bit 1 of byte 0x154
    /// - byte 0x151 and bits 0-5 of byte 0x152: i4 (14 bits)
    /// - byte 0x155 and bits 0-3 of byte 0x156: i5 / 4; bits 4-7 of byte 0x156 and byte 0x157: i6 / 4
    ///
    /// Bytes 0x150...0x157 (336...343) are the end of the footer section, after the footer CRC.
    ///
    /// With `background` 0xFF every bit that belongs to no field is set, to show it is ignored.
    private static func calibrationFRAM(background: UInt8) -> Data {
        var bytes = [UInt8](repeating: background, count: 344)
        let unused = background == 0xFF
        bytes[2] = 5 | (0b11010 << 3)                       // i1 = 5, low 5 bits of i2 = 794 (0x31A)
        bytes[3] = 0b11000 | (unused ? 0xE0 : 0)            // high 5 bits of i2
        bytes[0x150] = 18                                   // i3
        bytes[0x151] = 0x61                                 // i4 = 6753 = 0x1A61
        bytes[0x152] = 0x1A | (unused ? 0xC0 : 0)
        bytes[0x153] = unused ? 0xFF : 0
        bytes[0x154] = unused ? 0xFD : 0                    // bit 1 is the sign of i3
        bytes[0x155] = 0x62                                 // i5 / 4 = 2658 = 0xA62
        bytes[0x156] = 0x0A | (0x7 << 4)                    // i6 / 4 = 1783 = 0x6F7
        bytes[0x157] = 0x6F
        return Data(bytes)
    }

    /// 6 byte record with raw glucose 1000 and raw temperature 7000, plus the 9 bit temperature
    /// adjustment (bit 38, stored divided by 4) and its sign (bit 47).
    private static func record(adjustment: Int, negative: Bool) -> Data {
        precondition(adjustment < 512)
        var bytes: [UInt8] = [0xE8, 0x03, 0x00, 0x58, 0x1B, 0x00]
        bytes[4] |= UInt8(adjustment & 0b11) << 6
        bytes[5] = UInt8(adjustment >> 2) | (negative ? 0x80 : 0)
        return Data(bytes)
    }

    private static func localGlucose(raw: Int, temperature: Int, adjustment: Int = 0, _ info: LibreCalibrationInfo) -> Double {
        LibreMeasurement(rawGlucose: raw, rawTemperature: temperature, minuteCounter: 0, date: Date(timeIntervalSince1970: 0), temperatureAdjustment: adjustment, libre1DerivedAlgorithmParameters: nil)
            .glucoseValueFromRaw(libreCalibrationInfo: info)
    }

    // MARK: - calibration info

    func testCalibrationFieldsDecodeFromHandBuiltLibre1Layout() {
        let expected = Self.realisticCalibration()
        for background: UInt8 in [0x00, 0xFF] {
            let info = LibreCalibrationInfo(bytes: Self.calibrationFRAM(background: background), libreSensorType: .libre1)
            XCTAssertEqual(info.i1, 5, "background \(background)")
            XCTAssertEqual(info.i2, expected.i2, "background \(background)")
            XCTAssertEqual(info.i3, expected.i3, "background \(background)")
            XCTAssertEqual(info.i4, expected.i4, "background \(background)")
            XCTAssertEqual(info.i5, expected.i5, "background \(background)")
            XCTAssertEqual(info.i6, expected.i6, "background \(background)")
        }

        // sensor type unknown (older transmitter firmware) reads the same Libre 1 layout
        let unknownType = LibreCalibrationInfo(bytes: Self.calibrationFRAM(background: 0xFF), libreSensorType: nil)
        XCTAssertEqual(unknownType.i2, 794)
        XCTAssertEqual(unknownType.i6, 7132)
    }

    func testBitFieldWriteAndReadRoundTripWithoutTouchingOtherBits() {
        var generator = SplitMix64(seed: 0x524101)
        for _ in 0..<500 {
            let original = Data((0..<12).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let byteOffset = Int.random(in: 0...3, using: &generator)
            let bitOffset = Int.random(in: 0...40, using: &generator)
            let bitCount = Int.random(in: 1...24, using: &generator)
            let value = Int.random(in: 0..<(1 << bitCount), using: &generator)
            let firstBit = byteOffset * 8 + bitOffset

            let written = LibreCalibrationInfo.writeBits(original, byteOffset, bitOffset, bitCount, value)
            XCTAssertEqual(LibreCalibrationInfo.readBits(written, byteOffset, bitOffset, bitCount), value)

            for bit in 0..<(12 * 8) where bit < firstBit || bit >= firstBit + bitCount {
                XCTAssertEqual((written[bit / 8] >> (bit % 8)) & 1, (original[bit / 8] >> (bit % 8)) & 1,
                               "bit \(bit) changed by writing \(bitCount) bits at \(firstBit)")
            }
        }
    }

    // MARK: - measurement records

    func testRecordFlagBitsDoNotLeakIntoRawValues() {
        // Raw glucose is 13 bits and raw temperature 14 bits; the bits above them, byte 2 and
        // byte 5 hold flags and the temperature adjustment.
        for glucoseFlags in 0..<8 {
            for temperatureFlags in 0..<4 {
                for filler: UInt8 in [0x00, 0xFF] {
                    let bytes = Data([0x34, 0x12 | UInt8(glucoseFlags << 5), filler, 0x78, 0x25 | UInt8(temperatureFlags << 6), filler])
                    let measurement = LibreMeasurement(bytes: bytes, date: Date(timeIntervalSince1970: 0))
                    XCTAssertEqual(measurement.rawGlucose, 0x1234, "\(bytes.hexEncodedString())")
                    XCTAssertEqual(measurement.rawTemperature, 0x2578, "\(bytes.hexEncodedString())")
                }
            }
        }
    }

    func testTemperatureAdjustmentIsReadFromBit38AndMultipliedByFour() {
        let info = Self.realisticCalibration()
        let date = Date(timeIntervalSince1970: 0)

        let positive = LibreMeasurement(bytes: Self.record(adjustment: 101, negative: false), date: date)
        XCTAssertEqual(positive.rawGlucose, 1000)
        XCTAssertEqual(positive.rawTemperature, 7000, "the low adjustment bits share byte 4 with the temperature")
        XCTAssertEqual(positive.glucoseValueFromRaw(libreCalibrationInfo: info), Self.localGlucose(raw: 1000, temperature: 7000, adjustment: 404, info), accuracy: 1e-9)

        let negative = LibreMeasurement(bytes: Self.record(adjustment: 101, negative: true), date: date)
        XCTAssertEqual(negative.glucoseValueFromRaw(libreCalibrationInfo: info), Self.localGlucose(raw: 1000, temperature: 7000, adjustment: -404, info), accuracy: 1e-9)

        let neutral = LibreMeasurement(bytes: Self.record(adjustment: 0, negative: false), date: date)
        XCTAssertEqual(neutral.glucoseValueFromRaw(libreCalibrationInfo: info), Self.localGlucose(raw: 1000, temperature: 7000, info), accuracy: 1e-9)
        XCTAssertNotEqual(neutral.glucoseValueFromRaw(libreCalibrationInfo: info), positive.glucoseValueFromRaw(libreCalibrationInfo: info))
    }

    // MARK: - local algorithm

    func testLocalAlgorithmIsAffineInRawGlucose() {
        // The derived slope/offset parameters assume a straight line per temperature.
        let info = Self.realisticCalibration()
        for temperature in [6000, 7000, 8000, 9000] {
            let low = Self.localGlucose(raw: 1000, temperature: temperature, info)
            let middle = Self.localGlucose(raw: 2000, temperature: temperature, info)
            let high = Self.localGlucose(raw: 3000, temperature: temperature, info)
            XCTAssertEqual(low + high, 2 * middle, accuracy: 1e-9, "temperature \(temperature)")
            XCTAssertGreaterThan(high, low)
        }
    }

    func testCalibrationZeroPointDoesNotDependOnTemperature() {
        // i3 is the raw value of zero sensor current: the temperature factor multiplies zero there.
        let info = Self.realisticCalibration()
        let atZeroPoint = [6000, 7000, 9000].map { Self.localGlucose(raw: Int(info.i3), temperature: $0, info) }
        XCTAssertEqual(atZeroPoint[0], atZeroPoint[1], accuracy: 1e-9)
        XCTAssertEqual(atZeroPoint[0], atZeroPoint[2], accuracy: 1e-9)
        XCTAssertEqual(Self.localGlucose(raw: Int(info.i3), temperature: 7000, adjustment: -400, info), atZeroPoint[0], accuracy: 1e-9)

        // away from the zero point temperature does matter
        XCTAssertNotEqual(Self.localGlucose(raw: 1500, temperature: 6000, info), Self.localGlucose(raw: 1500, temperature: 9000, info), accuracy: 1e-3)

        // and i2 selects a different conversion table entry
        var otherTable = info
        otherTable.i2 = 1
        XCTAssertNotEqual(Self.localGlucose(raw: Int(info.i3), temperature: 7000, otherTable), atZeroPoint[0], accuracy: 1e-3)
    }

    func testDistanceBetweenI3AndI4SetsTheGain() {
        let info = Self.realisticCalibration()
        var doubledGain = info
        doubledGain.i4 = info.i3 + 2 * (info.i4 - info.i3)

        for raw in [500, 1500, 4000] {
            let original = Self.localGlucose(raw: raw, temperature: 7000, info) - Self.localGlucose(raw: Int(info.i3), temperature: 7000, info)
            let halved = Self.localGlucose(raw: raw, temperature: 7000, doubledGain) - Self.localGlucose(raw: Int(info.i3), temperature: 7000, doubledGain)
            XCTAssertEqual(halved, original / 2, accuracy: 1e-9, "raw \(raw)")
        }
    }

    // MARK: - derived algorithm parameters

    func testDerivedParametersDependOnlyOnCalibrationAndFooter() {
        // The parameters are cached per serial number and reused for every later reading, so they
        // must not change with the glucose data in the FRAM.
        var fram = Self.calibrationFRAM(background: 0x00)
        fram[320] = 0x34
        fram[321] = 0x12
        let reference = Libre1DerivedAlgorithmParameters(bytes: fram, serialNumber: "0M00009DHCR", libreSensorType: .libre1)

        var otherReadings = fram
        var generator = SplitMix64(seed: 0x524102)
        for index in Array(0..<2) + Array(4..<320) + Array(322..<0x150) {
            otherReadings[index] = UInt8.random(in: 0...255, using: &generator)
        }
        let same = Libre1DerivedAlgorithmParameters(bytes: otherReadings, serialNumber: "0M00009DHCR", libreSensorType: .libre1)
        XCTAssertEqual(same.description, reference.description)
        XCTAssertEqual(reference.isValidForFooterWithReverseCRCs, 0x1234, "footer CRC bytes are read low byte first")

        // the unknown sensor type of older transmitter firmware uses the same Libre 1 layout
        let unknownType = Libre1DerivedAlgorithmParameters(bytes: fram, serialNumber: "0M00009DHCR", libreSensorType: nil)
        XCTAssertEqual(unknownType.description, reference.description)

        // a different calibration gives different parameters
        var otherCalibration = fram
        otherCalibration[0x150] = 40
        let changed = Libre1DerivedAlgorithmParameters(bytes: otherCalibration, serialNumber: "0M00009DHCR", libreSensorType: .libre1)
        XCTAssertNotEqual(changed.offset_offset, reference.offset_offset)
    }

    // MARK: - persisted derived parameters

    func testStoredParametersInTheCurrentJSONFormatAreRead() {
        // The parameters are kept in UserDefaults as a JSON string between app launches and
        // updates; renaming a property would silently drop them and stop local parsing.
        let key = UserDefaults.Key.libre1DerivedAlgorithmParameters.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.set(#"{"slope_slope":1.35e-05,"slope_offset":-0.0005,"offset_slope":0.0035,"offset_offset":-13.5,"isValidForFooterWithReverseCRCs":50050,"extraSlope":1,"extraOffset":0,"serialNumber":"3MH00199R7W"}"#, forKey: key)
        let parameters = UserDefaults.standard.libre1DerivedAlgorithmParameters
        XCTAssertEqual(parameters?.slope_slope, 1.35e-05)
        XCTAssertEqual(parameters?.slope_offset, -0.0005)
        XCTAssertEqual(parameters?.offset_slope, 0.0035)
        XCTAssertEqual(parameters?.offset_offset, -13.5)
        XCTAssertEqual(parameters?.isValidForFooterWithReverseCRCs, 50050)
        XCTAssertEqual(parameters?.serialNumber, "3MH00199R7W")
    }

    func testStoredParametersKeepFullPrecision() {
        // Values derived from a real FRAM are long fractions; rounding them in storage would shift
        // every later reading of the sensor.
        let key = UserDefaults.Key.libre1DerivedAlgorithmParameters.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        let derived = Libre1DerivedAlgorithmParameters(bytes: Self.calibrationFRAM(background: 0x00), serialNumber: "0M00009DHCR", libreSensorType: .libre1)
        UserDefaults.standard.libre1DerivedAlgorithmParameters = derived
        let restored = UserDefaults.standard.libre1DerivedAlgorithmParameters
        XCTAssertEqual(restored?.slope_slope, derived.slope_slope)
        XCTAssertEqual(restored?.slope_offset, derived.slope_offset)
        XCTAssertEqual(restored?.offset_slope, derived.offset_slope)
        XCTAssertEqual(restored?.offset_offset, derived.offset_offset)
        XCTAssertEqual(restored?.description, derived.description)
    }

    func testUnreadableStoredParametersAreTreatedAsMissing() {
        // Missing parameters are recalculated from the next FRAM; a crash or garbage here is not.
        let key = UserDefaults.Key.libre1DerivedAlgorithmParameters.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        for stored in ["", "not json", "{}", #"{"slope_slope":"high"}"#, "null"] {
            UserDefaults.standard.set(stored, forKey: key)
            XCTAssertNil(UserDefaults.standard.libre1DerivedAlgorithmParameters, stored)
        }

        // clearing the parameters stores something that also reads back as missing
        UserDefaults.standard.libre1DerivedAlgorithmParameters = nil
        XCTAssertNil(UserDefaults.standard.libre1DerivedAlgorithmParameters)
    }

}
