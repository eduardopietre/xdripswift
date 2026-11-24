//
//  SensorHealthBannerLayoutTests.swift
//  xdripTests
//
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI
import UIKit
import XCTest
@testable import xdrip

/// The sensor health banner is the only place that shows the guidance of an episode, so the guidance
/// must never be cut off (#795).
@MainActor
final class SensorHealthBannerLayoutTests: XCTestCase {
    /// A narrow banner with a large text size, where the longer guidance texts need more than three lines.
    private let bannerWidth: CGFloat = 260
    private let dynamicTypeSize = DynamicTypeSize.accessibility2

    /// The banner's vertical padding (12 pt above and below).
    private let verticalPadding: CGFloat = 24

    /// The banner must be at least as tall as the guidance laid out over the full banner width.
    ///
    /// Inside the banner the guidance has less width than that (padding, chevron and dismiss button),
    /// so it needs at least as many lines; a shorter banner means the guidance was truncated.
    func testBannerShowsTheWholeGuidance() {
        let reasons: [SensorHealthReason] = [.persistentNoise, .flatline, .dexcomTemporarySensorIssue, .dexcomSensorFailure, .dexcomTransmitterFailure]

        for reason in reasons {
            let issue = makeIssue(reason: reason)

            let bannerHeight = height(of: SensorHealthBannerView(issue: issue, action: {}, dismiss: {}))
            let guidanceHeight = height(of: Text(issue.guidance)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true))

            XCTAssertGreaterThanOrEqual(bannerHeight, guidanceHeight + verticalPadding, "guidance cut off for \(reason)")
        }
    }

    /// The fitting height of a view at the banner width and text size.
    private func height<V: View>(of view: V) -> CGFloat {
        let controller = UIHostingController(rootView: view.environment(\.dynamicTypeSize, dynamicTypeSize))
        return controller.sizeThatFits(in: CGSize(width: bannerWidth, height: .greatestFiniteMagnitude)).height
    }

    private func makeIssue(reason: SensorHealthReason) -> SensorHealthIssue {
        SensorHealthIssue(
            id: "test",
            kind: .persistentNoise,
            severity: .caution,
            source: .dexcom,
            reason: reason,
            firstSeen: Date(timeIntervalSince1970: 1_800_000_000),
            sensorSessionID: "session",
            destination: .sensorManagement
        )
    }
}
