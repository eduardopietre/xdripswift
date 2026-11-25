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

    /// True while the app is only the host process of the unit tests (`xdripTests`).
    ///
    /// Xcode injects the unit tests into a running app. Starting the application services there
    /// would open the real Core Data store, scan for Bluetooth devices and start follower and
    /// Nightscout managers that observe the same `UserDefaults` the tests change, so the app would
    /// make network calls and write data in the background while tests run. The tests create the
    /// managers they need themselves, with an in-memory store. XCTest sets this variable only in
    /// a process that hosts unit tests; UI tests launch the app without it.
    static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

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

        if !Self.isHostingUnitTests {
            applicationCoordinator.start(rootTabStateModel: stateModel)
        }
    }

    var body: some Scene {
        WindowGroup {
            if Self.isHostingUnitTests {
                // The root views expect started services; an empty scene is enough to host tests.
                ConstantsAppColors.background
                    .ignoresSafeArea()
            } else {
                appContent
            }
        }
    }

    /// The root of the app's interface.
    private var appContent: some View {
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
