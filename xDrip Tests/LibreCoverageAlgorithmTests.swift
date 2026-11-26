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

    func testWriteBitsTruncatesValueToBitCount() {
        let written = LibreCalibrationInfo.writeBits(Data([0, 0]), 0, 0, 4, 0xFF)
        XCTAssertEqual(written, Data([0x0F, 0x00]))
    }

    // MARK: - LibreCalibrationInfo

    /// Values recorded from the current implementation for a real Libre 2 FRAM capture. They detect
    /// changes in parsing; they were not checked against another implementation.
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

    // MARK: - Libre1DerivedAlgorithmParameters

    /// Values recorded from the current implementation for a real Libre 2 FRAM capture, as above.
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

    // MARK: - PreLibre2 primitives

    func testDecryptFRAMProducesValidLibre1Image() {
        var decrypted = decryptedRealFRAM
        XCTAssertEqual(decrypted.count, 344)
        XCTAssertEqual(decrypted[4], 0x03)
        XCTAssertEqual(Int(decrypted[316]) + 256 * Int(decrypted[317]), 1030)
        XCTAssertTrue(Crc.LibreCrc(data: &decrypted, headerOffset: 0, libreSensorType: .libre2))
    }

}
