//
//  RootHomeChartRangeTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Covers how the Home chart picks, steps and sizes its visible range.
///
/// Pinch zoom produces arbitrary hour values that `closest(to:)` snaps to a supported range; a
/// stored value from an older version can also be outside the supported list. Ties between two
/// ranges must resolve the same way every time, otherwise the chart would flicker between widths
/// while the user pinches. The start date is computed by adding the negative `timeInterval` to the
/// chart end date, so its sign matters as much as its size.
final class RootHomeChartRangeTests: XCTestCase {

    /// Values halfway between two ranges snap to the shorter one (the first in `allCases`).
    func testClosestRangeResolvesTiesTowardsTheShorterRange() {
        XCTAssertEqual(RootHomeChartRange.closest(to: 4), .threeHours)
        XCTAssertEqual(RootHomeChartRange.closest(to: 6.5), .fiveHours)
        XCTAssertEqual(RootHomeChartRange.closest(to: 10), .eightHours)
        XCTAssertEqual(RootHomeChartRange.closest(to: 18), .twelveHours)
    }

    /// Just past the midpoint the longer range wins, and exact values map to themselves.
    func testClosestRangeSnapsToTheNearestRange() {
        XCTAssertEqual(RootHomeChartRange.closest(to: 4.01), .fiveHours)
        XCTAssertEqual(RootHomeChartRange.closest(to: 18.01), .twentyFourHours)
        for range in RootHomeChartRange.allCases {
            XCTAssertEqual(RootHomeChartRange.closest(to: range.rawValue), range)
        }
    }

    /// Out-of-range stored values (zero, negative, a week) are clamped to the nearest end.
    func testClosestRangeClampsValuesOutsideTheSupportedList() {
        XCTAssertEqual(RootHomeChartRange.closest(to: 0), .threeHours)
        XCTAssertEqual(RootHomeChartRange.closest(to: -6), .threeHours)
        XCTAssertEqual(RootHomeChartRange.closest(to: 168), .twentyFourHours)
    }

    /// The time interval looks back from the chart end date by exactly the range width.
    func testTimeIntervalLooksBackByTheRangeWidth() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(RootHomeChartRange.threeHours.timeInterval, -10_800)
        XCTAssertEqual(RootHomeChartRange.twentyFourHours.timeInterval, -86_400)
        for range in RootHomeChartRange.allCases {
            let start = end.addingTimeInterval(range.timeInterval)
            XCTAssertEqual(end.timeIntervalSince(start), range.rawValue * 3600)
        }
    }

    /// Stepping longer then shorter (and the reverse) returns to the same range, and stepping
    /// through the chain visits every range once in ascending order.
    func testStepsAreSymmetricAndVisitEveryRangeInOrder() {
        for range in RootHomeChartRange.allCases {
            if let longer = range.nextLongerRange {
                XCTAssertEqual(longer.nextShorterRange, range)
                XCTAssertGreaterThan(longer.rawValue, range.rawValue)
            }
            if let shorter = range.nextShorterRange {
                XCTAssertEqual(shorter.nextLongerRange, range)
            }
        }

        var visited: [RootHomeChartRange] = [.threeHours]
        while let next = visited.last?.nextLongerRange {
            visited.append(next)
        }
        XCTAssertEqual(visited, RootHomeChartRange.allCases)
    }

    /// Point diameters shrink as the range widens: the scaling baseline grows with the range, but
    /// more slowly, so wide ranges keep readable points.
    func testCircleScalingGrowsSlowerThanTheRange() {
        let ranges = RootHomeChartRange.allCases

        for (shorter, longer) in zip(ranges, ranges.dropFirst()) {
            XCTAssertGreaterThan(longer.glucoseCircleDiameterScalingHours, shorter.glucoseCircleDiameterScalingHours)
            XCTAssertLessThan(
                longer.glucoseCircleDiameterScalingHours / shorter.glucoseCircleDiameterScalingHours,
                longer.rawValue / shorter.rawValue
            )
        }
        XCTAssertEqual(RootHomeChartRange.threeHours.glucoseCircleDiameterScalingHours, RootHomeChartRange.threeHours.rawValue)
    }

    /// Settings titles show the whole number of hours followed by the localized unit.
    func testSettingsTitleShowsWholeHours() {
        XCTAssertEqual(RootHomeChartRange.threeHours.settingsTitle, "3 " + Texts_Common.hours)
        XCTAssertEqual(RootHomeChartRange.twentyFourHours.settingsTitle, "24 " + Texts_Common.hours)
    }
}
