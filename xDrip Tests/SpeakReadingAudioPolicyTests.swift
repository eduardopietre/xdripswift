//
//  SpeakReadingAudioPolicyTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import AVFoundation
import XCTest
@testable import xdrip

/// Tests for the audio session options used when readings are spoken.
///
/// Issue #741: during a run with music, the spoken glucose played over the music and was hard to
/// hear. An option, off by default, lowers ("ducks") other audio while a reading is spoken. The
/// app's audio session is shared with alarms and background keep-alive audio, so it is never
/// deactivated: only the category options change while speaking and are restored afterwards.
final class SpeakReadingAudioPolicyTests: XCTestCase {

    // MARK: - ducking (#741)

    func testOtherAudioIsLoweredWhileSpeakingWhenTheOptionIsOn() {
        let options = SpeakReadingAudioPolicy.categoryOptions(whileSpeaking: true, duckOtherAudio: true)

        XCTAssertTrue(options.contains(.duckOthers))
        XCTAssertTrue(options.contains(.mixWithOthers), "other audio keeps playing, only lowered")
    }

    func testOtherAudioIsRestoredAfterSpeaking() {
        XCTAssertEqual(SpeakReadingAudioPolicy.categoryOptions(whileSpeaking: false, duckOtherAudio: true), .mixWithOthers)
    }

    // MARK: - option off

    func testAudioSessionIsUnchangedWhenTheOptionIsOff() {
        XCTAssertEqual(SpeakReadingAudioPolicy.categoryOptions(whileSpeaking: true, duckOtherAudio: false), .mixWithOthers)
        XCTAssertEqual(SpeakReadingAudioPolicy.categoryOptions(whileSpeaking: false, duckOtherAudio: false), .mixWithOthers)
    }
}
