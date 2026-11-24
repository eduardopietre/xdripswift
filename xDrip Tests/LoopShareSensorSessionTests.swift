//
//  LoopShareSensorSessionTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Tests for the sensor session details shared with OS-AID apps.
///
/// Issue #329: an AID app that uploads the readings to Nightscout can create the sensor change
/// (SAGE) automatically when each reading carries the session start date and transmitter ID, as
/// the Dexcom app's data did for FreeAPS X. Readings shared by xDrip4iOS carried neither, so the
/// sensor change had to be entered by hand in Nightscout.
final class LoopShareSensorSessionTests: XCTestCase {

    private let sessionStart = Date(timeIntervalSince1970: 1_643_561_603.279)

    // MARK: - session details (#329)

    func testSessionStartDateIsSharedInTheFormatOfTheDexcomData() {
        let fields = LoopShareSensorSession.fields(sessionStartDate: sessionStart, transmitterID: "8RL6KF")

        XCTAssertEqual(fields["sessionStartDate"] as? String, "2022-01-30T16:53:23.279Z")
        XCTAssertEqual(fields["transmitterID"] as? String, "8RL6KF")
    }

    func testUnknownDetailsAreLeftOut() {
        XCTAssertTrue(LoopShareSensorSession.fields(sessionStartDate: nil, transmitterID: nil).isEmpty)
        XCTAssertNil(LoopShareSensorSession.fields(sessionStartDate: nil, transmitterID: "8RL6KF")["sessionStartDate"])
        XCTAssertNil(LoopShareSensorSession.fields(sessionStartDate: sessionStart, transmitterID: "")["transmitterID"])
    }

    /// The stored transmitter ID is kept after switching from a Dexcom to another CGM, so it is only
    /// shared while the active transmitter is a Dexcom; otherwise it would be sent with the session
    /// of a sensor it does not belong to.
    func testTransmitterIDIsOnlySharedForAnActiveDexcom() {
        XCTAssertEqual(LoopShareSensorSession.sharedTransmitterID(storedTransmitterID: "8G1234", activeTransmitterType: .dexcom), "8G1234")
        XCTAssertEqual(LoopShareSensorSession.sharedTransmitterID(storedTransmitterID: "DX01AB", activeTransmitterType: .dexcomG7), "DX01AB")
        XCTAssertNil(LoopShareSensorSession.sharedTransmitterID(storedTransmitterID: "8G1234", activeTransmitterType: .Libre3))
        XCTAssertNil(LoopShareSensorSession.sharedTransmitterID(storedTransmitterID: "8G1234", activeTransmitterType: nil))
    }
}
