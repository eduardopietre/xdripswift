//
//  TestScreenshots.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

/// Whether tests that render screens for visual review also capture and attach the images.
///
/// Capturing waits for the screen to settle and draws the whole view hierarchy, which takes
/// seconds per run, while nothing asserts on the images. They are captured only when the
/// `XDRIP_TEST_SCREENSHOTS` environment variable is `1`; with xcodebuild, pass
/// `TEST_RUNNER_XDRIP_TEST_SCREENSHOTS=1`.
enum TestScreenshots {
    static var areCaptured: Bool {
        ProcessInfo.processInfo.environment["XDRIP_TEST_SCREENSHOTS"] == "1"
    }
}
