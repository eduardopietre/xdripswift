//
//  LibreBlankCalibrationInfoTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for a Libre 1 reading with blank calibration info.
///
/// i2, read from FRAM, selects an entry of the calibration tables, from 1 to 1023. Blank or corrupt
/// calibration info has i2 0, which was used as index -1 and crashed the app.
final class LibreBlankCalibrationInfoTests: XCTestCase {

    /// Parameters derived from blank calibration info are all 0. They are stored per sensor and only
    /// derived again when the sensor changes, so every reading of that sensor would be 0.
    func testNoAlgorithmParametersAreDerivedFromBlankCalibrationInfo() {
        let blank = Data(repeating: 0, count: 344)
        XCTAssertNil(Libre1DerivedAlgorithmParameters.derived(bytes: blank, serialNumber: "blank", libreSensorType: .libre1))
    }

    func testAlgorithmParametersAreDerivedFromCalibrationInfoWithATableEntry() {
        // i2 is the 10 bits from bit 3 of byte 2
        let bytes = LibreCalibrationInfo.writeBits(Data(repeating: 0, count: 344), 2, 3, 0xa, 5)
        XCTAssertEqual(LibreCalibrationInfo(bytes: bytes, libreSensorType: .libre1).i2, 5)
        XCTAssertEqual(Libre1DerivedAlgorithmParameters.derived(bytes: bytes, serialNumber: "sensor", libreSensorType: .libre1)?.serialNumber, "sensor")
    }

    func testCalibrationTableIndexForEveryPossibleI2() {
        XCTAssertNil(LibreMeasurement.calibrationTableIndex(forI2: 0), "blank calibration info has no table entry")
        XCTAssertEqual(LibreMeasurement.calibrationTableIndex(forI2: 1), 0)
        XCTAssertEqual(LibreMeasurement.calibrationTableIndex(forI2: 1023), 1022)
    }

    func testBlankCalibrationInfoGivesZeroInsteadOfCrashing() {
        let info = LibreCalibrationInfo(bytes: Data(repeating: 0, count: 344), libreSensorType: .libre1)
        XCTAssertEqual(info.i2, 0)
        let measurement = LibreMeasurement(rawGlucose: 1500, rawTemperature: 7000)
        XCTAssertEqual(measurement.glucoseValueFromRaw(libreCalibrationInfo: info), 0)
        XCTAssertEqual(measurement.roundedGlucoseValueFromRaw(libreCalibrationInfo: info), 0)
    }
}
