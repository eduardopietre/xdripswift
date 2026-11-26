//
//  CalibrationListInsertionTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for adding a new calibration to the calibrations the calibrator works with.
///
/// The list is sorted from newest to oldest. The new calibration was inserted again for every older
/// calibration in the list, so one calibration counted several times in the weighted slope.
final class CalibrationListInsertionTests: XCTestCase {

    private struct Item: Equatable {
        let id: String
        let timeStamp: Date
    }

    private func item(_ id: String, minutesAgo: Double) -> Item {
        Item(id: id, timeStamp: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60))
    }

    private func insert(_ newItem: Item, into list: [Item]) -> [Item] {
        var list = list
        NewestFirstInsertion.insert(newItem, into: &list, id: \.id, timeStamp: \.timeStamp)
        return list
    }

    func testNewestCalibrationIsInsertedOnceAtTheStart() {
        let older = [item("b", minutesAgo: 60), item("c", minutesAgo: 120)]
        let newest = item("a", minutesAgo: 0)
        XCTAssertEqual(insert(newest, into: older), [newest] + older)
    }

    func testCalibrationBetweenOthersIsInsertedOnceInOrder() {
        let newer = item("a", minutesAgo: 0)
        let older = item("c", minutesAgo: 120)
        let middle = item("b", minutesAgo: 60)
        XCTAssertEqual(insert(middle, into: [newer, older]), [newer, middle, older])
    }

    func testOldestCalibrationIsAppended() {
        let list = [item("a", minutesAgo: 0), item("b", minutesAgo: 60)]
        let oldest = item("c", minutesAgo: 120)
        XCTAssertEqual(insert(oldest, into: list), list + [oldest])
    }

    func testCalibrationAlreadyInTheListIsNotAddedAgain() {
        let list = [item("a", minutesAgo: 0), item("b", minutesAgo: 60)]
        XCTAssertEqual(insert(item("b", minutesAgo: 60), into: list), list)
    }

    func testCalibrationIsAddedToAnEmptyList() {
        let only = item("a", minutesAgo: 0)
        XCTAssertEqual(insert(only, into: []), [only])
    }
}
