//
//  XdripApp.swift
//  xdrip
//
//  Created by Paul Plant on 12/7/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI

/// SwiftUI application entry point.
///
/// RootApplicationCoordinator owns the long-lived application services, while RootTabView owns
/// all root presentation and navigation. AppDelegate remains attached only for iOS callbacks that
/// do not yet have a SwiftUI equivalent, such as supported orientations and Home Screen actions.
@main @MainActor struct XdripApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var stateModel: RootTabStateModel

    private let applicationCoordinator: RootApplicationCoordinator
    private let tabTitles: RootTabTitles

    init() {
        let applicationCoordinator = RootApplicationCoordinator()
        let stateModel = RootTabStateModel()

        self.applicationCoordinator = applicationCoordinator
        self.tabTitles = RootTabTitles(
            home: NSLocalizedString("rootTab.home", tableName: "RootTab", bundle: .main, value: "Home", comment: "Home tab title."),
            treatments: NSLocalizedString("rootTab.treatments", tableName: "RootTab", bundle: .main, value: "Treatments", comment: "Treatments tab title."),
            statistics: NSLocalizedString("rootTab.statistics", tableName: "RootTab", bundle: .main, value: "Statistics", comment: "Statistics tab title."),
            devices: NSLocalizedString("rootTab.devices", tableName: "RootTab", bundle: .main, value: "Devices", comment: "Devices tab title."),
            settings: NSLocalizedString("rootTab.settings", tableName: "RootTab", bundle: .main, value: "Settings", comment: "Settings tab title.")
        )
        _stateModel = StateObject(wrappedValue: stateModel)

        // Unit tests run inside this app. Started services would observe and rewrite the same
        // UserDefaults.standard keys the tests set, and reach Bluetooth, follower downloads and
        // timers, so a test result would depend on what the app happened to do meanwhile.
        if !Self.isHostingUnitTests {
            applicationCoordinator.start(rootTabStateModel: stateModel)
        }
    }

    /// XCTest sets this variable in the process it injects the test bundle into.
    private static var isHostingUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Keep rotation resizes on the app palette instead of exposing the system window.
                ConstantsAppColors.background
                    .ignoresSafeArea()

                RootTabView(
                    stateModel: stateModel,
                    applicationCoordinator: applicationCoordinator,
                    tabTitles: tabTitles
                )
            }
            .background(ConstantsAppColors.background)
            .onOpenURL(perform: stateModel.receiveIncomingBackup)
        }
    }
}
