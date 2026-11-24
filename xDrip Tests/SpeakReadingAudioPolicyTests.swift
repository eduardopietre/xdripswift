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
/// hear. An option, off by default, lowers ("ducks") other audio while a reading is spoken.
///
/// iOS only returns other audio to full volume when the ducking session is deactivated: removing
/// the option from the still active session left the music lowered after the reading. The session
/// is therefore deactivated once the last reading has been spoken and activated again with the
/// options the app always uses, unless an app sound such as an alarm is playing.
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

    // MARK: - after speaking (#741)

    func testOtherAudioReturnsToFullVolumeAfterTheLastReading() {
        XCTAssertEqual(SpeakReadingAudioPolicy.afterSpeaking(duckedUtterancesLeft: 0, appSoundIsPlaying: false), .deactivateAndReactivate)
    }

    func testOtherAudioStaysLoweredWhileAnotherReadingIsSpoken() {
        XCTAssertEqual(SpeakReadingAudioPolicy.afterSpeaking(duckedUtterancesLeft: 1, appSoundIsPlaying: false), .nothing)
    }

    func testSessionIsNotDeactivatedWhileAnAppSoundIsPlaying() {
        // deactivating would stop an alarm that started while the reading was spoken
        XCTAssertEqual(SpeakReadingAudioPolicy.afterSpeaking(duckedUtterancesLeft: 0, appSoundIsPlaying: true), .restoreOptions)
    }

    // MARK: - follower keep-alive (#741)

    /// Other audio only returns to full volume when the session is deactivated, which would stop the
    /// silent audio of the follower keep-alive; so readings do not lower other audio then.
    func testOtherAudioIsNotLoweredWhileTheFollowerKeepAliveMayPlayAudio() {
        for type in [FollowerBackgroundKeepAliveType.normal, .aggressive, .continuous] {
            XCTAssertTrue(SpeakReadingAudioPolicy.keepAliveAudioMayPlay(isMaster: false, keepAliveType: type), "\(type)")
        }
        XCTAssertFalse(SpeakReadingAudioPolicy.lowersOtherAudio(optionIsOn: true, keepAliveAudioMayPlay: true))
    }

    func testOtherAudioIsLoweredWithoutKeepAliveAudio() {
        XCTAssertFalse(SpeakReadingAudioPolicy.keepAliveAudioMayPlay(isMaster: true, keepAliveType: .continuous), "a master plays no keep-alive audio")
        XCTAssertFalse(SpeakReadingAudioPolicy.keepAliveAudioMayPlay(isMaster: false, keepAliveType: .heartbeat))
        XCTAssertFalse(SpeakReadingAudioPolicy.keepAliveAudioMayPlay(isMaster: false, keepAliveType: .disabled))
        XCTAssertTrue(SpeakReadingAudioPolicy.lowersOtherAudio(optionIsOn: true, keepAliveAudioMayPlay: false))
        XCTAssertFalse(SpeakReadingAudioPolicy.lowersOtherAudio(optionIsOn: false, keepAliveAudioMayPlay: false))
    }

    // MARK: - missed end of a reading (#741)

    /// If iOS never reports the end of a reading, it must not keep other audio lowered for good: once
    /// the synthesizer is silent, the next reading starts from none.
    func testReadingsWhoseEndWasNotReportedAreDroppedOnceTheSynthesizerIsSilent() {
        XCTAssertEqual(SpeakReadingAudioPolicy.duckedReadingsStillSpoken(2, synthesizerIsSpeaking: false), 0)
        XCTAssertEqual(SpeakReadingAudioPolicy.duckedReadingsStillSpoken(2, synthesizerIsSpeaking: true), 2)
    }

    // MARK: - option off

    func testAudioSessionIsUnchangedWhenTheOptionIsOff() {
        XCTAssertEqual(SpeakReadingAudioPolicy.categoryOptions(whileSpeaking: true, duckOtherAudio: false), .mixWithOthers)
        XCTAssertEqual(SpeakReadingAudioPolicy.categoryOptions(whileSpeaking: false, duckOtherAudio: false), .mixWithOthers)
    }
}
