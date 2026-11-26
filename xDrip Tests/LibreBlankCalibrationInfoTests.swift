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

    func testCalibrationTableIndexForEveryPossibleI2() {
        XCTAssertNil(LibreMeasurement.calibrationTableIndex(forI2: 0), "blank calibration info has no table entry")
        XCTAssertEqual(LibreMeasurement.calibrationTableIndex(forI2: 1), 0)
        XCTAssertEqual(LibreMeasurement.calibrationTableIndex(forI2: 1023), 1022)
    }
}
