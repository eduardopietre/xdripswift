//
//  NightscoutFollowTypeTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the stored and encoded form of `NightscoutFollowType`.
///
/// The follow type is stored as Int16 in Core Data, encoded inside Watch and widget payloads and
/// mapped to rows in the settings picker. A changed raw value or a picker row mapped to the wrong
/// case would switch a Loop follower to OpenAPS parsing (or to none) without the user noticing.
final class NightscoutFollowTypeTests: XCTestCase {

    // MARK: - helpers

    /// Wraps the value in a struct because payloads always encode it as a property.
    private struct Payload: Codable, Equatable {
        let followType: NightscoutFollowType
    }

    // MARK: - tests

    func testPickerRowsMatchListOrder() {
        for (row, expected) in NightscoutFollowType.allCasesForList.enumerated() {
            XCTAssertEqual(NightscoutFollowType(forRowAt: row), expected, "row \(row)")
        }
        XCTAssertEqual(Set(NightscoutFollowType.allCasesForList), Set(NightscoutFollowType.allCases), "every case is selectable")
    }

    func testRawValuesAreStableAndUnknownValuesAreRejected() {
        XCTAssertEqual(NightscoutFollowType(rawValue: 0), NightscoutFollowType.none)
        XCTAssertEqual(NightscoutFollowType(rawValue: 1), .loop)
        XCTAssertEqual(NightscoutFollowType(rawValue: 2), .openAPS)
        XCTAssertNil(NightscoutFollowType(rawValue: 3))
    }

    func testCodableUsesTheRawIntegerValue() throws {
        let data = try JSONEncoder().encode(Payload(followType: .openAPS))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"followType":2}"#)

        for followType in NightscoutFollowType.allCases {
            let roundTrip = try JSONDecoder().decode(Payload.self, from: JSONEncoder().encode(Payload(followType: followType)))
            XCTAssertEqual(roundTrip.followType, followType)
        }
    }

    /// A payload from a newer app version with an unknown follow type must fail to decode rather
    /// than be mapped to a wrong type.
    func testDecodingAnUnknownOrStringValueFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(Payload.self, from: Data(#"{"followType":9}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Payload.self, from: Data(#"{"followType":"loop"}"#.utf8)))
    }

    func testDescriptionsAreDistinctAndUseSettingsTexts() {
        XCTAssertEqual(NightscoutFollowType.none.description, Texts_SettingsView.nightscoutFollowTypeNone)
        XCTAssertEqual(NightscoutFollowType.loop.description, Texts_SettingsView.nightscoutFollowTypeLoop)
        XCTAssertEqual(NightscoutFollowType.openAPS.description, Texts_SettingsView.nightscoutFollowTypeOpenAPS)
        XCTAssertEqual(NightscoutFollowType.openAPS.descriptionExpanded, Texts_SettingsView.nightscoutFollowTypeOpenAPSExpanded)
        XCTAssertEqual(Set(NightscoutFollowType.allCases.map(\.description)).count, NightscoutFollowType.allCases.count)
        XCTAssertEqual(Set(NightscoutFollowType.allCases.map(\.descriptionExpanded)).count, NightscoutFollowType.allCases.count)
    }
}
