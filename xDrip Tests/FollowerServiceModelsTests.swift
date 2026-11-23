//
//  FollowerServiceModelsTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the response models and region routing of the LibreLinkUp and Dexcom Share followers.
///
/// Both services answer with loosely specified JSON: LibreLinkUp signals wrong credentials, terms
/// to accept and region redirects through `status` and optional fields, and Dexcom Share has added
/// fields (such as a textual `Trend`) over time. A model that requires a field the server omits, or a
/// redirect region that maps to the wrong server, stops the follower from logging in at all.
final class FollowerServiceModelsTests: XCTestCase {

    // MARK: - helpers

    /// Mirrors the decoder of `LibreLinkUpFollowManager`, whose timestamps use a US-style UTC format.
    private let libreLinkUpDecoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy h:mm:ss a"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private var storedFollowerDataSourceType: FollowerDataSourceType = .nightscout

    override func setUp() {
        super.setUp()
        storedFollowerDataSourceType = UserDefaults.standard.followerDataSourceType
    }

    override func tearDown() {
        // the region URLs read the shared defaults, so restore whatever was stored before
        UserDefaults.standard.followerDataSourceType = storedFollowerDataSourceType
        super.tearDown()
    }

    // MARK: - LibreLinkUp responses

    func testLoginRedirectResponseSelectsTheServerOfTheRedirectRegion() throws {
        let json = #"{"status":0,"data":{"redirect":true,"region":"eu2"}}"#
        let response = try libreLinkUpDecoder.decode(Response<RequestLoginResponse>.self, from: Data(json.utf8))
        XCTAssertEqual(response.status, 0)
        XCTAssertEqual(response.data?.redirect, true)
        XCTAssertNil(response.data?.authTicket)
        XCTAssertNil(response.data?.user)

        UserDefaults.standard.followerDataSourceType = .libreLinkUp
        let region = try XCTUnwrap(LibreLinkUpRegion(from: try XCTUnwrap(response.data?.region)))
        XCTAssertEqual(region, .eu2)
        XCTAssertEqual(region.urlLogin, "https://api-eu2.libreview.io/llu/auth/login")
    }

    func testSuccessfulLoginResponseDecodesUserAndTicket() throws {
        let json = """
        {"status":0,"data":{"user":{"id":"a1b2c3d4-0000-1111-2222-333344445555","firstName":"Jane","country":"DE","uiLanguage":"de-DE",
          "consents":{"llu":{"policyAccept":1700000000}}},
          "messages":{"unread":0},"notifications":{"unresolved":0},
          "authTicket":{"token":"eyJhbGciOi.token","expires":1735689600,"duration":15552000000}}}
        """
        let response = try libreLinkUpDecoder.decode(Response<RequestLoginResponse>.self, from: Data(json.utf8))
        XCTAssertEqual(response.data?.user?.id, "a1b2c3d4-0000-1111-2222-333344445555")
        XCTAssertEqual(response.data?.user?.country, "DE")
        XCTAssertEqual(response.data?.authTicket?.token, "eyJhbGciOi.token")
        XCTAssertEqual(response.data?.authTicket?.expires, 1735689600)
        XCTAssertNil(response.data?.redirect)
    }

    /// Status 2 (bad credentials) and 4 (terms to accept) come without the usual `data` payload.
    func testErrorStatusesDecodeWithoutData() throws {
        let badCredentials = try libreLinkUpDecoder.decode(Response<RequestLoginResponse>.self, from: Data(#"{"status":2,"error":{"message":"notAuthenticated"}}"#.utf8))
        XCTAssertEqual(badCredentials.status, 2)
        XCTAssertNil(badCredentials.data)

        let terms = try libreLinkUpDecoder.decode(Response<RequestLoginResponse>.self, from: Data(#"{"status":4,"data":{"step":{"type":"tou","componentName":"AcceptDocument"}}}"#.utf8))
        XCTAssertEqual(terms.status, 4)
        XCTAssertNil(terms.data?.authTicket)
    }

    func testConnectionsResponseTakesTheFirstPatient() throws {
        let json = #"{"status":0,"data":[{"id":"x","patientId":"p-123","firstName":"A","lastName":"B"},{"patientId":"p-456"}]}"#
        let response = try libreLinkUpDecoder.decode(Response<[RequestConnectionsResponse]>.self, from: Data(json.utf8))
        XCTAssertEqual(response.data?.map(\.patientId), ["p-123", "p-456"])
    }

    func testGraphResponseDecodesUTCFactoryTimestampsAndSensor() throws {
        let json = """
        {"status":0,"data":{
          "connection":{"patientId":"p-123",
            "glucoseMeasurement":{"FactoryTimestamp":"11/23/2024 10:15:00 AM","Timestamp":"11/23/2024 11:15:00 AM","type":1,
              "ValueInMgPerDl":132,"TrendArrow":3,"MeasurementColor":1,"GlucoseUnits":1,"Value":132,"isHigh":false,"isLow":false},
            "sensor":{"deviceId":"","sn":"0K1234ABCD","a":1731888000,"w":60,"pt":4}},
          "activeSensors":[{"sensor":{"sn":"0K1234ABCD","a":1731888000},"device":{"dtid":40068}}],
          "graphData":[
            {"FactoryTimestamp":"11/23/2024 1:00:00 AM","ValueInMgPerDl":101.5,"Value":101},
            {"FactoryTimestamp":"11/23/2024 12:05:00 PM","ValueInMgPerDl":140}]}}
        """
        let response = try libreLinkUpDecoder.decode(Response<RequestGraphResponse>.self, from: Data(json.utf8))
        let data = try XCTUnwrap(response.data)

        // 2024-11-23T10:15:00Z: the factory timestamp is UTC, the local Timestamp is ignored
        XCTAssertEqual(data.connection?.glucoseMeasurement?.FactoryTimestamp, Date(timeIntervalSince1970: 1732356900))
        XCTAssertEqual(data.connection?.glucoseMeasurement?.ValueInMgPerDl, 132)
        XCTAssertEqual(data.connection?.sensor?.sn, "0K1234ABCD")
        XCTAssertEqual(data.connection?.sensor?.a, 1731888000)
        XCTAssertEqual(data.activeSensors?.first?.sensor?.sn, "0K1234ABCD")
        XCTAssertEqual(data.graphData?.map(\.ValueInMgPerDl), [101.5, 140])
        // 1 AM and 12 PM (noon) are the edge cases of the 12-hour clock
        XCTAssertEqual(data.graphData?.map(\.FactoryTimestamp), [Date(timeIntervalSince1970: 1732323600), Date(timeIntervalSince1970: 1732363500)])
    }

    // MARK: - LibreLinkUp regions

    /// The redirect region is a lowercased country code and the server host uses the same code, so
    /// parsing and URL building must agree for every region.
    func testEveryRegionCodeRoundTripsIntoItsOwnServer() {
        UserDefaults.standard.followerDataSourceType = .libreLinkUp
        for region in LibreLinkUpRegion.allCases where region != .notConfigured {
            let code = "\(region)"
            XCTAssertEqual(LibreLinkUpRegion(from: code.uppercased()), region)
            XCTAssertEqual(region.urlLogin, "https://api-\(code).libreview.io/llu/auth/login")
            XCTAssertEqual(region.urlConnections, "https://api-\(code).libreview.io/llu/connections")
            XCTAssertEqual(region.urlGraph(patientId: "p-1"), "https://api-\(code).libreview.io/llu/connections/p-1/graph")
            XCTAssertEqual(LibreLinkUpRegion.libreLinkUpRegionRawValue(rawValue: region.rawValue), region.rawValue)
        }
        XCTAssertEqual(LibreLinkUpRegion.notConfigured.urlConnections, "https://api.libreview.io/llu/connections")
        XCTAssertEqual(LibreLinkUpRegion(from: ""), .notConfigured)
    }

    /// The Russian service is a separate server: every region, even a redirect, must stay on it.
    func testRussianFollowerAlwaysUsesTheRussianServer() {
        UserDefaults.standard.followerDataSourceType = .libreLinkUpRussia
        for region in LibreLinkUpRegion.allCases {
            XCTAssertEqual(region.urlLogin, "https://api.libreview.ru/llu/auth/login", "\(region)")
            XCTAssertEqual(region.urlConnections, "https://api.libreview.ru/llu/connections", "\(region)")
            XCTAssertEqual(region.urlGraph(patientId: "p-9"), "https://api.libreview.ru/llu/connections/p-9/graph", "\(region)")
        }
    }

    // MARK: - Dexcom Share

    /// Older servers send `Trend` as a number and newer ones as a string; the model ignores it so both
    /// decode. The `Date(...)` strings are parsed later by the follow manager.
    func testDexcomShareGlucoseValuesDecodeWithEitherTrendFormat() throws {
        let json = """
        [{"WT":"Date(1732356900000)","ST":"Date(1732356900000)","DT":"Date(1732356900000+0100)","Value":132,"Trend":"Flat"},
         {"WT":"Date(1732356600000)","ST":"Date(1732356600000)","DT":"Date(1732356600000+0100)","Value":128,"Trend":4}]
        """
        let values = try JSONDecoder().decode([DexcomEGV].self, from: Data(json.utf8))
        XCTAssertEqual(values.map(\.Value), [132, 128])
        XCTAssertEqual(values.first?.DT, "Date(1732356900000+0100)")
        XCTAssertEqual(values.last?.WT, "Date(1732356600000)")
    }

    func testDexcomShareLoginRequestUsesTheServerFieldNames() throws {
        let request = DexcomShareLoginRequest(accountName: "user", applicationId: DexcomShareRegion.jp.applicationID, password: "secret")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String])
        XCTAssertEqual(json, ["accountName": "user", "applicationId": ConstantsDexcomShare.applicationIdJapan, "password": "secret"])
    }

    /// Japan has its own server and application ID; every other region, including an unset one,
    /// uses the original application ID and the matching server.
    func testDexcomShareRegionRouting() {
        XCTAssertEqual(DexcomShareRegion.us.baseURL.absoluteString, ConstantsDexcomShare.usBaseShareUrl)
        XCTAssertEqual(DexcomShareRegion.global.baseURL.absoluteString, ConstantsDexcomShare.globalBaseShareUrl)
        XCTAssertEqual(DexcomShareRegion.none.baseURL.absoluteString, ConstantsDexcomShare.globalBaseShareUrl)
        XCTAssertEqual(DexcomShareRegion.jp.baseURL.absoluteString, ConstantsDexcomShare.japanBaseShareUrl)
        for region in DexcomShareRegion.allCases {
            XCTAssertEqual(region.applicationID, region == .jp ? ConstantsDexcomShare.applicationIdJapan : ConstantsDexcomShare.applicationId, "\(region)")
            XCTAssertEqual(region.regionServerNumber, region == .none ? "" : String(region.rawValue), "\(region)")
            XCTAssertEqual(region.regionCountriesDescription.isEmpty, region == .none, "\(region)")
        }
    }

    func testDexcomShareRegionCodableUsesRawValue() throws {
        struct Stored: Codable { let region: DexcomShareRegion }
        XCTAssertEqual(String(data: try JSONEncoder().encode(Stored(region: .jp)), encoding: .utf8), #"{"region":3}"#)
        XCTAssertEqual(try JSONDecoder().decode(Stored.self, from: Data(#"{"region":2}"#.utf8)).region, .global)
        XCTAssertThrowsError(try JSONDecoder().decode(Stored.self, from: Data(#"{"region":4}"#.utf8)))
    }
}
