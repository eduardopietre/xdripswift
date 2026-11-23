//
//  Libre2FrameAssemblyEdgeCaseTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Edge cases of `Libre2FrameAssembler`, which joins the Bluetooth notifications of a directly
/// connected Libre 2 into 46 byte frames before they are decrypted.
///
/// Frames arrive about once a minute as notifications of up to 20 bytes. A wrong boundary at the
/// timeout or the size limit would glue fragments of two frames together (the CRC then rejects
/// the reading, which shows up as a missed reading) or report timeouts that did not happen.
final class Libre2FrameAssemblyEdgeCaseTests: XCTestCase {

    // MARK: - fixtures

    private static let frame = Data((0..<46).map { UInt8($0) })

    private let start = ContinuousClock.now

    // MARK: - tests

    func testAnySplitOfA46ByteFrameCompletesOnTheLastFragment() {
        var generator = SystemRandomNumberGenerator()
        var splits: [[Int]] = [[20, 20, 6], [46], Array(repeating: 1, count: 46)]
        for _ in 0..<50 {
            var sizes = [Int]()
            var remaining = 46
            while remaining > 0 {
                let size = Int.random(in: 1...min(20, remaining), using: &generator)
                sizes.append(size)
                remaining -= size
            }
            splits.append(sizes)
        }

        for sizes in splits {
            var assembler = Libre2FrameAssembler()
            var offset = 0
            for (index, size) in sizes.enumerated() {
                let result = assembler.append(Self.frame.subdata(in: offset..<(offset + size)), arrival: start)
                offset += size
                let expected: Libre2FrameAssembler.Result = index == sizes.count - 1 ? .complete(frame: Self.frame, assemblyDuration: 0) : .incomplete
                XCTAssertEqual(result.frameResult, expected, "split \(sizes), fragment \(index)")
                XCTAssertNil(result.timedOutPartialFrame)
            }
        }
    }

    func testFragmentArrivingExactlyAtTheTimeoutStillBelongsToTheFrame() {
        var assembler = Libre2FrameAssembler(assemblyTimeout: .seconds(3))
        _ = assembler.append(Self.frame.prefix(20), arrival: start)
        _ = assembler.append(Self.frame.subdata(in: 20..<40), arrival: start.advanced(by: .seconds(2)))
        let result = assembler.append(Self.frame.suffix(6), arrival: start.advanced(by: .seconds(3)))
        XCTAssertNil(result.timedOutPartialFrame)
        XCTAssertEqual(result.frameResult, .complete(frame: Self.frame, assemblyDuration: 3))
    }

    func testFragmentJustAfterTheTimeoutStartsANewFrame() {
        var assembler = Libre2FrameAssembler(assemblyTimeout: .seconds(3))
        _ = assembler.append(Self.frame.prefix(20), arrival: start)
        _ = assembler.append(Self.frame.subdata(in: 20..<40), arrival: start.advanced(by: .seconds(1)))
        let late = assembler.append(Self.frame.suffix(6), arrival: start.advanced(by: .milliseconds(3_001)))
        XCTAssertEqual(late.timedOutPartialFrame, Libre2FrameAssembler.TimedOutPartialFrame(discardedByteCount: 40, assemblyDuration: 3.001))
        XCTAssertEqual(late.frameResult, .incomplete, "the late fragment alone is not a frame")
    }

    func testSubSecondAssemblyDurationIsReported() {
        // The duration is logged to diagnose slow Bluetooth links, fractions of a second matter.
        var assembler = Libre2FrameAssembler()
        _ = assembler.append(Self.frame.prefix(20), arrival: start)
        _ = assembler.append(Self.frame.subdata(in: 20..<40), arrival: start.advanced(by: .milliseconds(250)))
        let result = assembler.append(Self.frame.suffix(6), arrival: start.advanced(by: .milliseconds(1_500)))
        XCTAssertEqual(result.frameResult, .complete(frame: Self.frame, assemblyDuration: 1.5))
    }

    func testGapBetweenCompleteFramesIsNotATimeout() {
        // Frames come about once a minute; the idle time after a complete frame must not be
        // reported as a timed out partial frame.
        var assembler = Libre2FrameAssembler()
        XCTAssertEqual(assembler.append(Self.frame, arrival: start).frameResult, .complete(frame: Self.frame, assemblyDuration: 0))

        let next = assembler.append(Self.frame.prefix(20), arrival: start.advanced(by: .seconds(60)))
        XCTAssertNil(next.timedOutPartialFrame)
        XCTAssertEqual(next.frameResult, .incomplete)
        let completed = assembler.append(Self.frame.suffix(26), arrival: start.advanced(by: .seconds(61)))
        XCTAssertEqual(completed.frameResult, .complete(frame: Self.frame, assemblyDuration: 1))
    }

    func testFragmentThatOverrunsTheFrameIsDiscardedWithThePartialFrame() {
        // Bytes beyond 46 mean fragments of two frames were mixed; splitting them at byte 46 would
        // hand a wrong frame to the decryption, so everything received is dropped.
        var assembler = Libre2FrameAssembler()
        XCTAssertEqual(assembler.append(Self.frame.prefix(40), arrival: start).frameResult, .incomplete)
        XCTAssertEqual(assembler.append(Self.frame.prefix(10), arrival: start).frameResult, .oversized(receivedByteCount: 50))

        // nothing of the overrun is carried into the next frame
        XCTAssertEqual(assembler.append(Self.frame.prefix(20), arrival: start).frameResult, .incomplete)
        XCTAssertEqual(assembler.append(Self.frame.suffix(26), arrival: start).frameResult, .complete(frame: Self.frame, assemblyDuration: 0))
    }

    func testTimeoutAndOverrunAreBothReportedForTheSameFragment() {
        // A late oversized fragment first discards the stale partial frame, then is too long itself.
        var assembler = Libre2FrameAssembler(assemblyTimeout: .seconds(3))
        _ = assembler.append(Self.frame.prefix(20), arrival: start)
        let result = assembler.append(Self.frame + Data([0xFF]), arrival: start.advanced(by: .seconds(5)))
        XCTAssertEqual(result.timedOutPartialFrame, Libre2FrameAssembler.TimedOutPartialFrame(discardedByteCount: 20, assemblyDuration: 5))
        XCTAssertEqual(result.frameResult, .oversized(receivedByteCount: 47))
    }

    func testResetDropsAPartialFrame() {
        // The transmitter resets the assembler when it is released; a half frame from before must
        // not be completed by the next notification.
        var assembler = Libre2FrameAssembler()
        _ = assembler.append(Self.frame.prefix(20), arrival: start)
        assembler.reset()
        let result = assembler.append(Self.frame, arrival: start.advanced(by: .seconds(1)))
        XCTAssertNil(result.timedOutPartialFrame)
        XCTAssertEqual(result.frameResult, .complete(frame: Self.frame, assemblyDuration: 0))
    }

}
