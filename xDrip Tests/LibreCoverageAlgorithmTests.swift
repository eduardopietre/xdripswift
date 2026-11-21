//
//  LibreCoverageAlgorithmTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class LibreCoverageAlgorithmTests: XCTestCase {
    private var decryptedRealFRAM: Data {
        Data(PreLibre2.decryptFRAM(
            Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID)),
            Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo)),
            Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoEncryptedFRAM))))
    }

    // MARK: - LibreCalibrationInfo bit helpers

    func testReadBitsReadsLittleEndianBitFieldsAcrossBytes() {
        let buffer = Data([0b1011_0110, 0b0000_0011, 0xFF])
        XCTAssertEqual(LibreCalibrationInfo.readBits(buffer, 0, 0, 8), 0b1011_0110)
        XCTAssertEqual(LibreCalibrationInfo.readBits(buffer, 0, 1, 3), 0b011)
        XCTAssertEqual(LibreCalibrationInfo.readBits(buffer, 0, 4, 6), 0b11_1011)
        XCTAssertEqual(LibreCalibrationInfo.readBits(buffer, 1, 0, 2), 3)
        XCTAssertEqual(LibreCalibrationInfo.readBits(buffer, 0, 16, 8), 0xFF)
    }

    func testReadBitsWithZeroCountReturnsZero() {
        XCTAssertEqual(LibreCalibrationInfo.readBits(Data([0xFF]), 0, 0, 0), 0)
    }

    func testWriteBitsRoundTripsAndPreservesNeighbouringBits() {
        let original = Data([0xFF, 0x00, 0xAA, 0x55])
        let written = LibreCalibrationInfo.writeBits(original, 0, 6, 12, 0xABC)
        XCTAssertEqual(LibreCalibrationInfo.readBits(written, 0, 6, 12), 0xABC)
        XCTAssertEqual(LibreCalibrationInfo.readBits(written, 0, 0, 6), 0x3F)
        XCTAssertEqual(LibreCalibrationInfo.readBits(written, 0, 18, 14), LibreCalibrationInfo.readBits(original, 0, 18, 14))
        XCTAssertEqual(original, Data([0xFF, 0x00, 0xAA, 0x55]), "the input buffer is copied")
    }

    func testWriteBitsTruncatesValueToBitCount() {
        let written = LibreCalibrationInfo.writeBits(Data([0, 0]), 0, 0, 4, 0xFF)
        XCTAssertEqual(written, Data([0x0F, 0x00]))
    }

    // MARK: - LibreCalibrationInfo

    func testCalibrationInfoOfRealLibre2Sensor() {
        let info = LibreCalibrationInfo(bytes: decryptedRealFRAM, libreSensorType: .libre2)
        XCTAssertEqual(info.i1, 0)
        XCTAssertEqual(info.i2, 794)
        XCTAssertEqual(info.i3, 18)
        XCTAssertEqual(info.i4, 6753)
        XCTAssertEqual(info.i5, 10632)
        XCTAssertEqual(info.i6, 7132)
    }

    func testCalibrationInfoUsesNegativeFlagForI3() {
        var bytes = Data(repeating: 0, count: 344)
        bytes[0x150] = 25
        XCTAssertEqual(LibreCalibrationInfo(bytes: bytes, libreSensorType: .libre1).i3, 25)
        bytes = LibreCalibrationInfo.writeBits(bytes, 0x150, 0x21, 1, 1)
        XCTAssertEqual(LibreCalibrationInfo(bytes: bytes, libreSensorType: .libre1).i3, -25)
    }

    func testCalibrationInfoUsesProHOffsets() {
        var bytes = Data(repeating: 0, count: 344)
        bytes = LibreCalibrationInfo.writeBits(bytes, 26, 0, 3, 5)
        bytes = LibreCalibrationInfo.writeBits(bytes, 26, 3, 10, 300)
        bytes = LibreCalibrationInfo.writeBits(bytes, 56, 0, 8, 7)
        bytes = LibreCalibrationInfo.writeBits(bytes, 56, 8, 14, 4000)
        bytes = LibreCalibrationInfo.writeBits(bytes, 56, 0x28, 12, 100)
        bytes = LibreCalibrationInfo.writeBits(bytes, 56, 0x34, 12, 200)
        let proH = LibreCalibrationInfo(bytes: bytes, libreSensorType: .libreProH)
        XCTAssertEqual(proH.i1, 5)
        XCTAssertEqual(proH.i2, 300)
        XCTAssertEqual(proH.i3, 7)
        XCTAssertEqual(proH.i4, 4000)
        XCTAssertEqual(proH.i5, 400)
        XCTAssertEqual(proH.i6, 800)
        let libre1 = LibreCalibrationInfo(bytes: bytes, libreSensorType: .libre1)
        XCTAssertEqual(libre1.i2, 0)
        XCTAssertEqual(libre1.i4, 0)
    }

    func testCalibrationInfoIsCodable() throws {
        let info = LibreCalibrationInfo(bytes: decryptedRealFRAM, libreSensorType: .libre2)
        let decoded = try JSONDecoder().decode(LibreCalibrationInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(decoded.i2, info.i2)
        XCTAssertEqual(decoded.i6, info.i6)
    }

    // MARK: - Libre1DerivedAlgorithmParameters

    func testDerivedParametersOfRealLibre2Sensor() {
        let parameters = Libre1DerivedAlgorithmParameters(bytes: decryptedRealFRAM, serialNumber: "3MH00199R7W", libreSensorType: .libre2)
        XCTAssertEqual(parameters.slope_slope, 1.35e-05, accuracy: 1e-12)
        XCTAssertEqual(parameters.slope_offset, -0.0005, accuracy: 1e-12)
        XCTAssertEqual(parameters.offset_slope, 0.0035, accuracy: 1e-12)
        XCTAssertEqual(parameters.offset_offset, -13.5, accuracy: 1e-9)
        XCTAssertEqual(parameters.isValidForFooterWithReverseCRCs, 50050)
        XCTAssertEqual(parameters.extraSlope, 1)
        XCTAssertEqual(parameters.extraOffset, 0)
        XCTAssertEqual(parameters.serialNumber, "3MH00199R7W")
    }

    func testDerivedParametersInterpolateTheFourCalibrationCorners() {
        let bytes = decryptedRealFRAM
        let parameters = Libre1DerivedAlgorithmParameters(bytes: bytes, serialNumber: "S", libreSensorType: .libre2)
        let info = LibreCalibrationInfo(bytes: bytes, libreSensorType: .libre2)
        for (raw, temperature) in [(1000, 6000), (3000, 6000), (1000, 9000), (3000, 9000)] {
            let expected = LibreMeasurement(rawGlucose: raw, rawTemperature: temperature).roundedGlucoseValueFromRaw2(libreCalibrationInfo: info)
            let slope = parameters.slope_slope * Double(temperature) + parameters.offset_slope
            let offset = parameters.slope_offset * Double(temperature) + parameters.offset_offset
            XCTAssertEqual(slope * Double(raw) + offset, expected, accuracy: 1e-6, "raw \(raw) temperature \(temperature)")
        }
    }

    func testDerivedParametersFooterChecksumUsesProHFooter() {
        var bytes = Data(repeating: 0, count: 344)
        bytes = LibreCalibrationInfo.writeBits(bytes, 26, 3, 10, 1)
        bytes = LibreCalibrationInfo.writeBits(bytes, 56, 8, 14, 4000)
        bytes = LibreCalibrationInfo.writeBits(bytes, 56, 0x34, 12, 2000)
        bytes[72] = 0x34
        bytes[73] = 0x12
        let parameters = Libre1DerivedAlgorithmParameters(bytes: bytes, serialNumber: "P", libreSensorType: .libreProH)
        XCTAssertEqual(parameters.isValidForFooterWithReverseCRCs, 0x1234)
    }

    func testDerivedParametersDescriptionAndCodableRoundTrip() throws {
        let parameters = Libre1DerivedAlgorithmParameters(slope_slope: 1, slope_offset: 2, offset_slope: 3, offset_offset: 4, isValidForFooterWithReverseCRCs: 5, extraSlope: 6, extraOffset: 7, sensorSerialNumber: "ABC")
        XCTAssertEqual(parameters.description, "LibreDerivedAlgorithmParameters: slopeslope: 1.0, slopeoffset: 2.0, offsetoffset: 4.0, offsetSlope: 3.0, extraSlope: 6.0, extraOffset: 7.0, isValidForFooterWithReverseCRCs: 5, serialNumber: ABC")
        let decoded = try JSONDecoder().decode(Libre1DerivedAlgorithmParameters.self, from: JSONEncoder().encode(parameters))
        XCTAssertEqual(decoded.description, parameters.description)
    }

    func testDerivedParametersPersistInUserDefaults() {
        let snapshot = LibreCoverageDefaultsSnapshot()
        defer { snapshot.restore() }
        let parameters = Libre1DerivedAlgorithmParameters(slope_slope: 0.5, slope_offset: 0, offset_slope: 1, offset_offset: 0, isValidForFooterWithReverseCRCs: 1, extraSlope: 1, extraOffset: 0, sensorSerialNumber: "X1")
        UserDefaults.standard.libre1DerivedAlgorithmParameters = parameters
        XCTAssertEqual(UserDefaults.standard.libre1DerivedAlgorithmParameters?.serialNumber, "X1")
        XCTAssertEqual(UserDefaults.standard.libre1DerivedAlgorithmParameters?.slope_slope, 0.5)
        UserDefaults.standard.libre1DerivedAlgorithmParameters = nil
        XCTAssertNil(UserDefaults.standard.libre1DerivedAlgorithmParameters)
    }

    // MARK: - LibreMeasurement

    func testMeasurementDecodesSixByteRecordWithoutParameters() {
        let date = Date(timeIntervalSince1970: 1_000)
        let measurement = LibreMeasurement(bytes: Data([0x34, 0xF2, 0x00, 0x78, 0xC5, 0x00]), date: date)
        XCTAssertEqual(measurement.rawGlucose, 0x1234)
        XCTAssertEqual(measurement.rawTemperature, 0x0578)
        XCTAssertEqual(measurement.slope, 0.1)
        XCTAssertEqual(measurement.offset, 0)
        XCTAssertEqual(measurement.date, date)
        XCTAssertEqual(measurement.temperatureAlgorithmGlucose, 0)
    }

    func testMeasurementAppliesTemperatureDependentParameters() {
        let parameters = Libre1DerivedAlgorithmParameters(slope_slope: 0.001, slope_offset: 0.01, offset_slope: 0.1, offset_offset: -20, isValidForFooterWithReverseCRCs: 0, extraSlope: 2, extraOffset: 3, sensorSerialNumber: "S")
        // raw glucose 1000, raw temperature 6000
        let bytes = Data([0xE8, 0x03, 0x00, 0x70, 0x17, 0x00])
        let measurement = LibreMeasurement(bytes: bytes, date: Date(), libre1DerivedAlgorithmParameters: parameters)
        let slope = 0.001 * 6000 + 0.1
        let offset = 0.01 * 6000 - 20
        XCTAssertEqual(measurement.temperatureAlgorithmGlucose, (slope * 1000 + offset) * 2 + 3, accuracy: 1e-9)
    }

    func testMeasurementFromRawValuesMatchesMeasurementFromBytes() {
        let parameters = Libre1DerivedAlgorithmParameters(bytes: decryptedRealFRAM, serialNumber: "S", libreSensorType: .libre2)
        let date = Date(timeIntervalSince1970: 5_000)
        let fromBytes = LibreMeasurement(bytes: Data([0x88, 0x02, 0x00, 0x00, 0x1E, 0x00]), date: date, libre1DerivedAlgorithmParameters: parameters)
        let fromRaw = LibreMeasurement(rawGlucose: 0x288, rawTemperature: 0x1E00, minuteCounter: 3, date: date, temperatureAdjustment: 0, libre1DerivedAlgorithmParameters: parameters)
        XCTAssertEqual(fromRaw.rawGlucose, fromBytes.rawGlucose)
        XCTAssertEqual(fromRaw.rawTemperature, fromBytes.rawTemperature)
        XCTAssertEqual(fromRaw.temperatureAlgorithmGlucose, fromBytes.temperatureAlgorithmGlucose, accuracy: 1e-9)
        XCTAssertGreaterThan(fromRaw.temperatureAlgorithmGlucose, 0)
        let withoutParameters = LibreMeasurement(rawGlucose: 100, rawTemperature: 100, minuteCounter: 0, date: date, temperatureAdjustment: 4, libre1DerivedAlgorithmParameters: nil)
        XCTAssertEqual(withoutParameters.temperatureAlgorithmGlucose, 0)
        XCTAssertEqual(withoutParameters.slope, 0.1)
    }

    func testTemperatureAdjustmentChangesLocalAlgorithmResult() {
        let info = LibreCalibrationInfo(bytes: decryptedRealFRAM, libreSensorType: .libre2)
        let neutral = Data([0xE8, 0x03, 0x00, 0x58, 0x1B, 0x00])
        let positive = LibreCalibrationInfo.writeBits(neutral, 0, 0x26, 9, 100)
        let negative = LibreCalibrationInfo.writeBits(positive, 0, 0x2F, 1, 1)
        let base = LibreMeasurement(bytes: neutral, date: Date()).glucoseValueFromRaw(libreCalibrationInfo: info)
        let up = LibreMeasurement(bytes: positive, date: Date()).glucoseValueFromRaw(libreCalibrationInfo: info)
        let down = LibreMeasurement(bytes: negative, date: Date()).glucoseValueFromRaw(libreCalibrationInfo: info)
        XCTAssertNotEqual(up, base)
        XCTAssertNotEqual(down, base)
        XCTAssertTrue((up - base) * (down - base) < 0, "positive and negative adjustments move the result in opposite directions")
    }

    func testLocalAlgorithmIsMonotonicInRawGlucose() {
        let info = LibreCalibrationInfo(bytes: decryptedRealFRAM, libreSensorType: .libre2)
        let values = stride(from: 500, through: 4000, by: 500).map {
            LibreMeasurement(rawGlucose: $0, rawTemperature: 7000).glucoseValueFromRaw(libreCalibrationInfo: info)
        }
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count)
    }

    func testRoundedLocalAlgorithmVariantsAgree() {
        let info = LibreCalibrationInfo(bytes: decryptedRealFRAM, libreSensorType: .libre2)
        let measurement = LibreMeasurement(rawGlucose: 1234, rawTemperature: 7321)
        let exact = measurement.glucoseValueFromRaw(libreCalibrationInfo: info)
        XCTAssertEqual(measurement.roundedGlucoseValueFromRaw2(libreCalibrationInfo: info), exact.rounded())
        XCTAssertEqual(measurement.roundedGlucoseValueFromRaw(libreCalibrationInfo: info), Int(exact.rounded()))
    }

    // MARK: - PreLibre2 primitives

    func testOpShiftsAndXorsTheKeyHalves() {
        XCTAssertEqual(PreLibre2.op(0, 0xA0C5, 0x6860), 0)
        XCTAssertEqual(PreLibre2.op(1, 0xA0C5, 0x6860), 0x6860)
        XCTAssertEqual(PreLibre2.op(2, 0xA0C5, 0x6860), 0xA0C5)
        XCTAssertEqual(PreLibre2.op(3, 0xA0C5, 0x6860), 0xA0C5 ^ 0x6860)
        XCTAssertEqual(PreLibre2.op(0x100, 0xA0C5, 0x6860), 0x40)
    }

    func testWordCombinesHighAndLowBytes() {
        XCTAssertEqual(PreLibre2.word(0x12, 0x34), 0x1234)
        XCTAssertEqual(PreLibre2.word(0xFF, 0xFF), 0xFFFF)
        XCTAssertEqual(PreLibre2.word(0, 7), 7)
    }

    func testProcessCryptoMatchesProcessCrypto2WithReversedOutput() {
        let input: [UInt16] = [0x1234, 0xABCD, 0x0F0F, 0x30DC]
        let viaKeyTable = PreLibre2.processCrypto(input: input)
        let viaExplicitKey = PreLibre2.processCrypto2(input[0], input[1], input[2], input[3], 0xA0C5, 0x6860)
        XCTAssertEqual(viaKeyTable, Array(viaExplicitKey.reversed()))
    }

    func testPrepareVariablesMixesUIDWithInputsAndKey() {
        let uid = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        XCTAssertEqual(PreLibre2.prepareVariables(sensorUID: uid, x: 0x10, y: 0x20), [0x0605 + 0x30, 0x0403, 0x0201 + 0x20, 0x241A ^ 0x14C6])
        XCTAssertEqual(PreLibre2.prepareVariables2(sensorUID: uid, i1: 1, i2: 2, i3: 3, i4: 4), [0x0606, 0x0405, 0x0204, 0x14CA])
    }

    func testPrepareVariablesWrapsAround16Bits() {
        let uid = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0])
        XCTAssertEqual(PreLibre2.prepareVariables(sensorUID: uid, x: 2, y: 3), [4, 0xFFFF, 3, 0x30DC])
        XCTAssertEqual(PreLibre2.prepareVariables2(sensorUID: uid, i1: 1, i2: 2, i3: 3, i4: 0xFFFF), [0, 1, 2, 0x14C5])
    }

    func testUsefulFunctionMatchesKnownVector() {
        let uid = LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID)
        XCTAssertEqual(PreLibre2.usefulFunction(sensorUID: uid, x: 0x1B, y: 0x1B6A), [130, 113, 98, 105])
    }

    func testDecryptFRAMProducesValidLibre1Image() {
        var decrypted = decryptedRealFRAM
        XCTAssertEqual(decrypted.count, 344)
        XCTAssertEqual(decrypted[4], 0x03)
        XCTAssertEqual(Int(decrypted[316]) + 256 * Int(decrypted[317]), 1030)
        XCTAssertTrue(Crc.LibreCrc(data: &decrypted, headerOffset: 0, libreSensorType: .libre2))
    }

    func testDecryptFRAMIsAnInvolution() {
        let uid = Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID))
        let info = Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo))
        let plain = LibreCoverageFRAM().bytes()
        XCTAssertEqual(PreLibre2.decryptFRAM(uid, info, PreLibre2.decryptFRAM(uid, info, plain)), plain)
    }

    func testDecryptFRAMUsesDifferentKeyStreamForLibreUS() {
        let uid = Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID))
        let zero = [UInt8](repeating: 0, count: 344)
        let eu = PreLibre2.decryptFRAM(uid, [0x9D, 0x08, 0x30, 0x01, 0xFB, 0x30], zero)
        let us = PreLibre2.decryptFRAM(uid, [0xE5, 0x08, 0x30, 0x01, 0xFB, 0x30], zero)
        let usE6 = PreLibre2.decryptFRAM(uid, [0xE6, 0x08, 0x30, 0x01, 0xFB, 0x30], zero)
        XCTAssertNotEqual(eu, us)
        XCTAssertEqual(us, usE6)
        XCTAssertEqual(eu.count, 344)
    }

    func testDecryptFRAMKeyStreamDependsOnUID() {
        let info: [UInt8] = [0x9D, 0x08, 0x30, 0x01, 0xFB, 0x30]
        let zero = [UInt8](repeating: 0, count: 344)
        let a = PreLibre2.decryptFRAM([1, 2, 3, 4, 5, 6, 7, 8], info, zero)
        let b = PreLibre2.decryptFRAM([1, 2, 3, 4, 5, 7, 7, 8], info, zero)
        XCTAssertNotEqual(a, b)
    }
}
