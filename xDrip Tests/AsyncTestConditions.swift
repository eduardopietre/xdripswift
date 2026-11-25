//
//  AsyncTestConditions.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import XCTest

/// The polling behind `waitForCondition`, kept free of XCTest so it can be tested on every platform.
///
/// Main-actor isolated, so the condition is read on the main actor between checks, like the state of
/// the managers and Core Data contexts the tests look at. A nonisolated async function would run the
/// condition on the generic executor, off the main actor, racing with that state.
@MainActor
enum AsyncTestConditions {

    /// Checks `condition` every `interval` seconds until it holds (true) or `timeout` passes (false).
    static func poll(timeout: TimeInterval, interval: TimeInterval = 0.005, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return true
    }

    /// Checks `value` every `interval` seconds until it has not changed for `quietPeriod` (true) or
    /// `timeout` passes (false).
    static func stable<Value: Equatable>(quietPeriod: TimeInterval, timeout: TimeInterval, interval: TimeInterval = 0.005,
                                         _ value: () -> Value) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last = value()
        var unchangedSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let current = value()
            if current != last {
                last = current
                unchangedSince = Date()
            } else if Date().timeIntervalSince(unchangedSince) >= quietPeriod {
                return true
            }
        }
        return false
    }
}

extension XCTestCase {

    /// Waits until `condition` holds, checking it every few milliseconds, and fails the test when
    /// `timeout` passes first.
    ///
    /// Use it instead of a fixed `Task.sleep` before an assertion: it returns as soon as the work
    /// is done (fast on a quick machine) and still waits long enough on a slow CI machine (no
    /// flaky failures). The condition is evaluated on the caller's actor, so a `@MainActor` test
    /// can read main-actor state, and the main queue keeps running between checks.
    ///
    /// - Returns: whether the condition held before the timeout, for tests that continue either way.
    @discardableResult
    @MainActor
    func waitForCondition(_ message: @autoclosure () -> String = "condition not met",
                          timeout: TimeInterval = 5,
                          pollInterval: TimeInterval = 0.005,
                          file: StaticString = #filePath,
                          line: UInt = #line,
                          _ condition: () -> Bool) async -> Bool {
        if await AsyncTestConditions.poll(timeout: timeout, interval: pollInterval, condition) {
            return true
        }
        XCTFail("\(message()) within \(timeout) s", file: file, line: line)
        return false
    }

    /// Waits until `value` has stopped changing for `quietPeriod`, e.g. the number of requests a
    /// stub has received, so background work started by the test has finished before teardown
    /// restores settings. Returns early when nothing happens, unlike a fixed sleep; does not fail
    /// the test on timeout, because it is meant for setUp and tearDown.
    @discardableResult
    @MainActor
    func waitUntilStable<Value: Equatable>(quietPeriod: TimeInterval = 0.05, timeout: TimeInterval = 2,
                                           _ value: () -> Value) async -> Bool {
        await AsyncTestConditions.stable(quietPeriod: quietPeriod, timeout: timeout, value)
    }

    /// Lets work that was already queued run: pending main-queue blocks and tasks that are ready.
    ///
    /// Use it where a test needs the effects of a `DispatchQueue.main.async` or an unstructured
    /// `Task` started by the code under test, and nothing observable says when it is done. It
    /// replaces sleeps of a few hundred milliseconds with a few yields.
    @MainActor
    func drainPendingWork(iterations: Int = 3) async {
        for _ in 0..<iterations {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            await Task.yield()
        }
    }
}
