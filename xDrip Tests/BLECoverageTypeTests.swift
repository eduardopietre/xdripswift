//
//  BLECoverageTypeTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import CoreData
import XCTest
@testable import xdrip

final class BLECoverageTypeTests: XCTestCase {

    // MARK: - BluetoothPeripheralType

    func testCategoriesForEveryPeripheralType() {
        let expected: [BluetoothPeripheralType: BluetoothPeripheralCategory] = [
            .M5StackType: .M5Stack, .M5StickCType: .M5Stack,
            .Libre2Type: .CGM, .Libre3Type: .CGM, .MiaoMiaoType: .CGM, .BubbleType: .CGM, .DexcomType: .CGM,
            .DexcomG7Type: .CGM, .MedtrumTouchCareNanoType: .CGM,
            .DexcomG7HeartBeatType: .HeartBeat, .Libre3HeartBeatType: .HeartBeat, .OmniPodHeartBeatType: .HeartBeat,
        ]
        XCTAssertEqual(BluetoothPeripheralType.allCases.count, expected.count)
        for type in BluetoothPeripheralType.allCases {
            XCTAssertEqual(type.category(), expected[type], type.rawValue)
            XCTAssertEqual(type.canShowTransmitterReadSuccess(), expected[type] == .CGM, type.rawValue)
        }
    }

    func testCapabilityFlagsPerPeripheralType() {
        let needsId: Set<BluetoothPeripheralType> = [.DexcomType, .Libre3HeartBeatType, .DexcomG7Type, .DexcomG7HeartBeatType]
        let webOOP: Set<BluetoothPeripheralType> = [.BubbleType, .MiaoMiaoType, .Libre2Type]
        let nonFixed: Set<BluetoothPeripheralType> = [.Libre2Type, .BubbleType, .MiaoMiaoType]
        let intermittent: Set<BluetoothPeripheralType> = [.DexcomType, .DexcomG7Type, .DexcomG7HeartBeatType]
        for type in BluetoothPeripheralType.allCases {
            XCTAssertEqual(type.needsTransmitterId(), needsId.contains(type), type.rawValue)
            XCTAssertEqual(type.canWebOOP(), webOOP.contains(type), type.rawValue)
            XCTAssertEqual(type.canUseNonFixedSlope(), nonFixed.contains(type), type.rawValue)
            XCTAssertEqual(type.usesIntermittentConnection, intermittent.contains(type), type.rawValue)
            XCTAssertEqual(type.needsNFCScanToConnect(), type == .Libre2Type, type.rawValue)
        }
    }

    func testRawValuesUsedInStoredConfiguration() {
        XCTAssertEqual(BluetoothPeripheralType.DexcomType.rawValue, "Dexcom G6/ONE")
        XCTAssertEqual(BluetoothPeripheralType.DexcomG7HeartBeatType.rawValue, "Dexcom G7/ONE+/Stelo")
        XCTAssertEqual(BluetoothPeripheralType.DexcomG7Type.rawValue, "DexcomG7Type")
        XCTAssertEqual(BluetoothPeripheralType(rawValue: "Medtrum Nano"), .MedtrumTouchCareNanoType)
        XCTAssertNil(BluetoothPeripheralType(rawValue: "Unknown"))
    }

    func testDexcomG6TransmitterIdValidation() {
        let type = BluetoothPeripheralType.DexcomType
        XCTAssertNil(type.validateTransmitterId(transmitterId: "8G1234"))
        XCTAssertEqual(type.validateTransmitterId(transmitterId: "8G123"), Texts_ErrorMessages.TransmitterIDShouldHaveLength6)
        XCTAssertEqual(type.validateTransmitterId(transmitterId: "8G12345"), Texts_ErrorMessages.TransmitterIDShouldHaveLength6)
        XCTAssertEqual(type.validateTransmitterId(transmitterId: "!!!!!!"), Texts_ErrorMessages.DexcomTransmitterIDInvalidCharacters)
    }

    func testDexcomG7TransmitterIdValidation() {
        let type = BluetoothPeripheralType.DexcomG7Type
        XCTAssertNil(type.validateTransmitterId(transmitterId: ""))
        XCTAssertNil(type.validateTransmitterId(transmitterId: "DXCM12"))
        XCTAssertNil(type.validateTransmitterId(transmitterId: "dx01"))
        XCTAssertEqual(type.validateTransmitterId(transmitterId: "AB1234"), Texts_ErrorMessages.DexcomG7TypeTransmitterIDWrongPattern)
        XCTAssertEqual(type.validateTransmitterId(transmitterId: "DXCM123"), Texts_ErrorMessages.TransmitterIDShouldHaveMaximumLength6)
        XCTAssertNil(BluetoothPeripheralType.M5StackType.validateTransmitterId(transmitterId: "anything"))
    }

    func testCreatedPeripheralsReportTheirOwnType() {
        let coreData = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreData.mainManagedObjectContext
        for (index, type) in BluetoothPeripheralType.allCases.enumerated() {
            let address = "ADDR-\(index)"
            let peripheral = type.createNewBluetoothPeripheral(withAddress: address, withName: "Name\(index)", nsManagedObjectContext: context)
            XCTAssertEqual(peripheral.bluetoothPeripheralType(), type, type.rawValue)
            XCTAssertEqual(peripheral.blePeripheral.address, address)
            XCTAssertEqual(peripheral.blePeripheral.name, "Name\(index)")
        }
    }

    // MARK: - BluetoothPeripheralCategory

    func testCategoryIndexesAndLists() {
        XCTAssertEqual(BluetoothPeripheralCategory.CGM.index(), 0)
        XCTAssertEqual(BluetoothPeripheralCategory.M5Stack.index(), 1)
        XCTAssertEqual(BluetoothPeripheralCategory.HeartBeat.index(), 2)
        XCTAssertEqual(BluetoothPeripheralCategory.listOfCategories(), ["CGM", "M5Stack", "Follower Heartbeat"])
        XCTAssertEqual(BluetoothPeripheralCategory.listOfBluetoothPeripheralTypes(withCategory: "M5Stack"), ["M5Stack", "M5StickC"])
        XCTAssertEqual(BluetoothPeripheralCategory.listOfBluetoothPeripheralTypes(withCategory: "Follower Heartbeat").count, 3)
        XCTAssertEqual(BluetoothPeripheralCategory.listOfBluetoothPeripheralTypes(withCategory: "CGM").count, 7)
        XCTAssertTrue(BluetoothPeripheralCategory.listOfBluetoothPeripheralTypes(withCategory: "nope").isEmpty)
    }

    // MARK: - CGMTransmitterType

    func testTransmitterTypeSensorTypeAndPolicies() {
        let sensorTypes: [CGMTransmitterType: CGMSensorType] = [.dexcom: .Dexcom, .dexcomG7: .Dexcom, .miaomiao: .Libre, .Bubble: .Libre,
                                                               .Libre2: .Libre, .Libre3: .Libre, .medtrumTouchCareNano: .Medtrum]
        for type in CGMTransmitterType.allCases {
            XCTAssertEqual(type.sensorType(), sensorTypes[type], type.rawValue)
            XCTAssertTrue(type.canDetectNewSensor())
            XCTAssertEqual(type.osAidSharingPolicy, type == .medtrumTouchCareNano ? .blocked : .allowed)
        }
    }

    func testManualStartBatteryUnitsAndAlertLevels() {
        let manual: Set<CGMTransmitterType> = [.dexcom, .miaomiao, .Bubble, .Libre2]
        let units: [CGMTransmitterType: String] = [.dexcom: "voltB", .dexcomG7: "voltB", .miaomiao: "%", .Bubble: "%", .Libre2: "%", .Libre3: "", .medtrumTouchCareNano: ""]
        let levels: [CGMTransmitterType: Int] = [.dexcom: 270, .dexcomG7: 215, .miaomiao: 20, .Bubble: 20, .Libre2: 20, .Libre3: 20, .medtrumTouchCareNano: 20]
        for type in CGMTransmitterType.allCases {
            XCTAssertEqual(type.allowManualSensorStart(), manual.contains(type), type.rawValue)
            XCTAssertEqual(type.batteryUnit(), units[type], type.rawValue)
            XCTAssertEqual(type.defaultBatteryAlertLevel(), levels[type], type.rawValue)
        }
    }

    func testDetailedDescriptionsForEachFamily() {
        XCTAssertEqual(CGMTransmitterType.dexcom.detailedDescription(transmitterID: "4ABCDE"), "Dexcom G5")
        XCTAssertEqual(CGMTransmitterType.dexcom.detailedDescription(transmitterID: "512345"), "Dexcom ONE")
        XCTAssertEqual(CGMTransmitterType.dexcom.detailedDescription(transmitterID: "c12345"), "Dexcom ONE")
        XCTAssertEqual(CGMTransmitterType.dexcom.detailedDescription(transmitterID: "912345"), "Dexcom")
        XCTAssertEqual(CGMTransmitterType.dexcom.detailedDescription(transmitterID: nil), "Dexcom")
        XCTAssertEqual(CGMTransmitterType.Libre3.detailedDescription(transmitterID: nil), "Libre 3/3 Plus")
        XCTAssertEqual(CGMTransmitterType.medtrumTouchCareNano.detailedDescription(transmitterID: nil), "Medtrum Nano Pump CGM")
        XCTAssertEqual(CGMTransmitterType.miaomiao.detailedDescription(transmitterID: nil), "MiaoMiao")
        XCTAssertEqual(CGMTransmitterType.Bubble.detailedDescription(transmitterID: "x"), "Bubble")
    }

    func testLibre2DescriptionDependsOnMaxSensorAge() {
        let key = UserDefaults.Key.activeSensorMaxSensorAgeInDays.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.activeSensorMaxSensorAgeInDays = 15
        XCTAssertEqual(CGMTransmitterType.Libre2.detailedDescription(transmitterID: nil), "Libre 2 Plus EU")
        UserDefaults.standard.activeSensorMaxSensorAgeInDays = 14
        XCTAssertEqual(CGMTransmitterType.Libre2.detailedDescription(transmitterID: nil), "Libre 2 EU")
    }

    func testDetailedDescriptionWithoutArgumentUsesActiveTransmitterId() {
        let key = UserDefaults.Key.activeSensorTransmitterId.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.activeSensorTransmitterId = "DX02AB"
        XCTAssertEqual(CGMTransmitterType.dexcomG7.detailedDescription(), "Dexcom ONE+")
        UserDefaults.standard.activeSensorTransmitterId = "8G1234"
        XCTAssertEqual(CGMTransmitterType.dexcom.detailedDescription(), "Dexcom G6")
    }

    func testProductNameResolvers() {
        XCTAssertEqual(Libre3ProductNameResolver.title(wearMinutes: 20_160), "Libre 3")
        XCTAssertEqual(Libre3ProductNameResolver.title(wearMinutes: 21_600), "Libre 3 Plus")
        XCTAssertEqual(Libre3ProductNameResolver.title(wearMinutes: nil), "Libre 3/3 Plus")
        XCTAssertNil(DexcomProductNameResolver.title(transmitterType: .dexcom, transmitterID: "912345", bluetoothName: nil))
        XCTAssertNil(DexcomProductNameResolver.title(transmitterType: .dexcom, transmitterID: "", bluetoothName: nil))
        XCTAssertNil(DexcomProductNameResolver.title(transmitterType: .dexcomG7, transmitterID: nil, bluetoothName: nil))
        XCTAssertNil(DexcomProductNameResolver.title(transmitterType: .dexcomG7, transmitterID: nil, bluetoothName: "DX"))
        XCTAssertNil(DexcomProductNameResolver.title(transmitterType: .dexcomG7, transmitterID: nil, bluetoothName: "ABCDEF"))
        XCTAssertEqual(DexcomProductNameResolver.title(transmitterType: .dexcomG7, transmitterID: nil, bluetoothName: "DXCMAB"), "Dexcom G7")
        XCTAssertNil(DexcomProductNameResolver.title(transmitterType: .Libre2, transmitterID: "DX01AB", bluetoothName: nil))
    }

    // MARK: - CGMTransmitter defaults and calibration status

    func testCGMTransmitterProtocolDefaults() {
        let transmitter = MinimalCGMTransmitter()
        transmitter.setNonFixedSlopeEnabled(enabled: true)
        transmitter.setWebOOPEnabled(enabled: true)
        transmitter.requestNewReading()
        transmitter.startSensor(sensorCode: "1234", startDate: Date())
        transmitter.stopSensor(stopDate: Date())
        XCTAssertFalse(transmitter.isNonFixedSlopeEnabled())
        XCTAssertFalse(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.overruleIsWebOOPEnabled())
        XCTAssertFalse(transmitter.isAnubisG6())
        XCTAssertNil(transmitter.maxSensorAgeInDays())
        XCTAssertNil(transmitter.sensorWarmupDurationInMinutes())
        XCTAssertNil(transmitter.transmitterCalibrationStatus())
        XCTAssertTrue(transmitter.needsSensorStartTime())
        XCTAssertFalse(transmitter.needsSensorStartCode())
        XCTAssertFalse(transmitter.shouldWarnOnLargeCalibrationStep())
        XCTAssertTrue(transmitter.nonWebOOPAllowed())
    }

    func testCalibrationStatusTraceDescriptions() {
        let statuses: [CGMTransmitterCalibrationStatus] = [.queued, .sentAwaitingResponse, .processing, .completedHigh, .completedLow, .rejected(.outsideRange), .notPermitted]
        XCTAssertEqual(statuses.map(\.traceDescription), ["queued", "sent, awaiting response", "processing", "completed with high confidence",
                                                         "completed with low confidence", "rejected: outside range", "calibration not permitted"])
    }

    // MARK: - BluetoothTransmitter enums and Core Bluetooth descriptions

    func testStartScanningResultDescriptions() {
        let results: [BluetoothTransmitter.startScanningResult] = [.success, .alreadyScanning, .poweredOff, .alreadyConnected, .connecting,
                                                                   .unknown, .unauthorized, .nfcScanNeeded, .other(reason: "x")]
        XCTAssertEqual(results.map { $0.description() }, ["success", "alreadyScanning", "poweredOff", "alreadyConnected", "connecting",
                                                          "unknown", "unauthorized", "nfcScanNeeded", "other reason : x"])
        XCTAssertEqual(BluetoothTransmitter.startScanningResult.other(reason: "a"), .other(reason: "a"))
        XCTAssertNotEqual(BluetoothTransmitter.startScanningResult.other(reason: "a"), .other(reason: "b"))
    }

    func testCoreBluetoothStateDescriptions() {
        XCTAssertEqual([CBPeripheralState.connected, .connecting, .disconnected, .disconnecting].map { $0.description() },
                       ["connected", "connecting", "disconnected", "disconnecting"])
        XCTAssertEqual([CBManagerState.poweredOff, .poweredOn, .resetting, .unauthorized, .unknown, .unsupported].map { $0.toString() },
                       ["poweredOff", "poweredOn", "resetting", "unauthorized", "unknown", "unsupported"])
    }

    // MARK: - M5Stack wire helpers

    func testM5StackSplitsTextIntoNumberedPackets() throws {
        let packets = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: "ABCDEFGHIJ", maxBytesInOneBLEPacket: 7, opCode: 0x13))
        XCTAssertEqual(packets, [Data([0x13, 1, 3, 0x41, 0x42, 0x43, 0x44]), Data([0x13, 2, 3, 0x45, 0x46, 0x47, 0x48]), Data([0x13, 3, 3, 0x49, 0x4A])])
        let exact = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: "ABCD", maxBytesInOneBLEPacket: 7, opCode: 0x13))
        XCTAssertEqual(exact, [Data([0x13, 1, 1, 0x41, 0x42, 0x43, 0x44])])
        XCTAssertEqual(M5StackUtilities.splitTextInBLEPackets(text: "", maxBytesInOneBLEPacket: 20, opCode: 1), [])
    }

    func testM5StackPacketReassemblesOutOfOrderPackets() throws {
        let packets = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: "secret-password", maxBytesInOneBLEPacket: 8, opCode: 0x0E))
        let assembler = M5StackPacket()
        for packet in packets.reversed() {
            XCTAssertNil(assembler.getText())
            assembler.addNewPacket(value: packet)
        }
        XCTAssertEqual(assembler.getText(), "secret-password")
    }

    func testM5StackPacketIgnoresInvalidHeadersAndResetsOnCountChange() {
        let assembler = M5StackPacket()
        assembler.addNewPacket(value: Data([0x0E, 1]))
        assembler.addNewPacket(value: Data([0x0E, 0, 1, 0x41]))
        assembler.addNewPacket(value: Data([0x0E, 2, 1, 0x41]))
        assembler.addNewPacket(value: Data([0x0E, 1, 0, 0x41]))
        XCTAssertNil(assembler.getText())
        assembler.addNewPacket(value: Data([0x0E, 1, 2, 0x41]))
        assembler.addNewPacket(value: Data([0x0E, 1, 1, 0x5A]))
        XCTAssertEqual(assembler.getText(), "Z")
        let empty = M5StackPacket()
        empty.addNewPacket(value: Data([0x0E, 1, 1]))
        XCTAssertNil(empty.getText())
    }

    func testM5StackMessagesAndOpcodes() {
        XCTAssertNil(M5StackAuthenticateTXMessage(password: "").data)
        XCTAssertEqual(M5StackAuthenticateTXMessage(password: "pw").data, Data([0x0A, 0x70, 0x77]))
        XCTAssertEqual(M5StackReadBlePassWordTxMessage().data, Data([0x09]))
        XCTAssertEqual(M5StackTransmitterOpCodeTx.allCases.count, 16)
        var descriptions = Set<String>()
        for opCode in M5StackTransmitterOpCodeRx.allCases {
            XCTAssertTrue(descriptions.insert(opCode.description).inserted)
        }
        XCTAssertEqual(M5StackTransmitterOpCodeRx(rawValue: 0x21)?.description, "heartbeat")
        XCTAssertEqual(M5StackTransmitterOpCodeRx(rawValue: 0x0B)?.description, "authenticateSuccessRx")
    }
}

private final class MinimalCGMTransmitter: CGMTransmitter {
    func cgmTransmitterType() -> CGMTransmitterType { .dexcom }
    func getCBUUID_Service() -> String { "" }
    func getCBUUID_Receive() -> String { "" }
}
