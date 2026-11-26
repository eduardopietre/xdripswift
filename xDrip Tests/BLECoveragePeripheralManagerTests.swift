//
//  BLECoveragePeripheralManagerTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import CoreData
import XCTest
@testable import xdrip

final class BLECoveragePeripheralManagerTests: XCTestCase {
    private var defaults: DexcomCoverageDefaultsSnapshot!
    private var coreData: CoreDataManager!
    private var manager: BluetoothPeripheralManager!
    private var cgmRecorder: DexcomCoverageRecorder!
    private var cgmInfoChangedCount = 0
    private var presentationChangedCount = 0
    private var messages = [(String, String)]()

    override func setUp() {
        super.setUp()
        defaults = DexcomCoverageDefaultsSnapshot()
        coreData = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        cgmRecorder = DexcomCoverageRecorder()
        manager = BluetoothPeripheralManager(coreDataManager: coreData, cgmTransmitterDelegate: cgmRecorder,
                                             messageHandler: { [weak self] in self?.messages.append(($0, $1)) },
                                             heartBeatFunction: nil,
                                             cgmTransmitterInfoChanged: { [weak self] in self?.cgmInfoChangedCount += 1 },
                                             connectionPresentationChanged: { [weak self] in self?.presentationChangedCount += 1 })
    }

    override func tearDown() {
        manager.getBluetoothTransmitters().forEach { $0.prepareForRelease() }
        manager.tempBlueToothTransmitterWhileScanningForNewBluetoothPeripheral?.prepareForRelease()
        // The manager observes UserDefaults.standard. One left alive would react to the defaults other
        // tests change, on whatever thread they change them, and touch its Core Data objects there.
        weak var releasedManager = manager
        manager = nil
        XCTAssertNil(releasedManager, "the manager must be released at the end of the test")
        defaults.restore()
        super.tearDown()
    }

    func testCreatedTransmittersMapBackToTheirPeripheralType() {
        let cases: [(BluetoothPeripheralType, String?)] = [
            (.M5StackType, nil), (.M5StickCType, nil), (.DexcomType, "8GCOV2"), (.DexcomG7Type, nil),
            (.DexcomG7HeartBeatType, "DXCMHB"), (.Libre3HeartBeatType, "ABC123"), (.OmniPodHeartBeatType, nil),
            (.MedtrumTouchCareNanoType, nil), (.BubbleType, nil), (.MiaoMiaoType, nil),
        ]
        for (type, transmitterId) in cases {
            let transmitter = manager.createNewTransmitter(type: type, transmitterId: transmitterId, dexcomG6BluetoothSlot: .medicalDevice, bluetoothTransmitterDelegate: nil)
            XCTAssertEqual(manager.getTransmitterType(for: transmitter), type, type.rawValue)
            XCTAssertTrue(transmitter.bluetoothTransmitterDelegate === manager, type.rawValue)
            transmitter.prepareForRelease()
        }
        let g6 = manager.createNewTransmitter(type: .DexcomType, transmitterId: "8GCOV3", dexcomG6BluetoothSlot: .medicalDevice, bluetoothTransmitterDelegate: nil)
        XCTAssertEqual((g6 as? CGMG5Transmitter)?.bluetoothSlot, .medicalDevice)
        XCTAssertEqual((g6 as? CGMG5Transmitter)?.useOtherApp, false)
        g6.prepareForRelease()
        let g7 = manager.createNewTransmitter(type: .DexcomG7Type, transmitterId: nil, dexcomG6BluetoothSlot: .mobileApp, bluetoothTransmitterDelegate: nil)
        XCTAssertEqual((g7 as? CGMG7Transmitter)?.useOtherApp, true)
        g7.prepareForRelease()
    }

    func testInsertKeepsPeripheralsOrderedByCategory() {
        let context = coreData.mainManagedObjectContext
        let heartbeat = BluetoothPeripheralType.OmniPodHeartBeatType.createNewBluetoothPeripheral(withAddress: "A1", withName: "BOARD", nsManagedObjectContext: context)
        let m5 = BluetoothPeripheralType.M5StackType.createNewBluetoothPeripheral(withAddress: "A2", withName: "M5", nsManagedObjectContext: context)
        let cgm = BluetoothPeripheralType.MedtrumTouchCareNanoType.createNewBluetoothPeripheral(withAddress: "A3", withName: "MT1", nsManagedObjectContext: context)
        XCTAssertEqual(insert(heartbeat), 0)
        XCTAssertEqual(insert(m5), 0)
        XCTAssertEqual(insert(cgm), 0)
        XCTAssertEqual(manager.getBluetoothPeripherals().map(\.blePeripheral.address), ["A3", "A2", "A1"])
        XCTAssertEqual(manager.firstIndexInBluetoothPeripherals(bluetoothPeripheral: heartbeat), 2)
        let unknown = BluetoothPeripheralType.M5StickCType.createNewBluetoothPeripheral(withAddress: "ZZ", withName: "M5", nsManagedObjectContext: context)
        XCTAssertNil(manager.firstIndexInBluetoothPeripherals(bluetoothPeripheral: unknown))
        XCTAssertNil(manager.getBluetoothTransmitter(for: unknown, createANewOneIfNecesssary: true))
    }

    func testTransmittersAreCreatedOnDemandFromStoredPeripherals() throws {
        let context = coreData.mainManagedObjectContext
        let types: [BluetoothPeripheralType] = [.M5StackType, .M5StickCType, .DexcomType, .DexcomG7Type, .DexcomG7HeartBeatType,
                                                .Libre3HeartBeatType, .OmniPodHeartBeatType, .MedtrumTouchCareNanoType, .BubbleType, .MiaoMiaoType]
        for (index, type) in types.enumerated() {
            let peripheral = type.createNewBluetoothPeripheral(withAddress: UUID().uuidString, withName: "DEV\(index)", nsManagedObjectContext: context)
            peripheral.blePeripheral.transmitterId = type == .DexcomType ? "8GCOV4" : "DXCM\(index)"
            peripheral.blePeripheral.shouldconnect = false
            insert(peripheral)
            XCTAssertNil(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: false), type.rawValue)
            let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: true), type.rawValue)
            XCTAssertEqual(manager.getTransmitterType(for: transmitter), type)
            XCTAssertEqual(transmitter.deviceAddress, peripheral.blePeripheral.address)
            XCTAssertTrue(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: true) === transmitter)
            XCTAssertEqual(manager.getBluetoothPeripheral(for: transmitter)?.blePeripheral.address, peripheral.blePeripheral.address)
        }
        XCTAssertEqual(manager.getBluetoothTransmitters().count, types.count)
        XCTAssertNil(manager.getCGMTransmitter())
    }

    func testActiveCGMPeripheralBecomesCurrentTransmitter() throws {
        let peripheral = BluetoothPeripheralType.MedtrumTouchCareNanoType.createNewBluetoothPeripheral(withAddress: UUID().uuidString, withName: "MT9", nsManagedObjectContext: coreData.mainManagedObjectContext)
        insert(peripheral)
        let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: true))
        XCTAssertEqual(manager.currentCgmTransmitterAddress, peripheral.blePeripheral.address)
        XCTAssertEqual(cgmInfoChangedCount, 1)
        XCTAssertTrue(manager.getCGMTransmitter() === transmitter as? CGMTransmitter)
        manager.receivedNewValue(webOOPEnabled: true, for: peripheral)
        manager.receivedNewValue(nonFixedSlopeEnabled: true, for: peripheral)
        XCTAssertEqual(cgmInfoChangedCount, 3)
        manager.setBluetoothTransmitterToNil(forBluetoothPeripheral: peripheral)
        XCTAssertNil(manager.currentCgmTransmitterAddress)
        XCTAssertEqual(cgmInfoChangedCount, 4)
    }

    func testDisconnectDisablesStoredPeripheral() throws {
        let peripheral = BluetoothPeripheralType.OmniPodHeartBeatType.createNewBluetoothPeripheral(withAddress: UUID().uuidString, withName: "BOARD", nsManagedObjectContext: coreData.mainManagedObjectContext)
        insert(peripheral)
        let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: true))
        manager.connect(to: peripheral)
        manager.disconnect(fromBluetoothPeripheral: peripheral)
        XCTAssertFalse(peripheral.blePeripheral.shouldconnect)
        manager.didDisconnectFrom(bluetoothTransmitter: transmitter)
        XCTAssertNotNil(peripheral.blePeripheral.lastConnectionStatusChangeTimeStamp)
        manager.deviceDidUpdateBluetoothState(state: .poweredOff, bluetoothTransmitter: transmitter)
    }

    func testDidConnectToNewScannedTransmitterCreatesPeripheral() throws {
        let address = UUID().uuidString
        let transmitter = M5StackBluetoothTransmitter(address: address, name: "M5Stack-X", bluetoothTransmitterDelegate: manager,
                                                      m5StackBluetoothTransmitterDelegate: manager, blePassword: nil, bluetoothPeripheralType: .M5StackType)
        manager.tempBlueToothTransmitterWhileScanningForNewBluetoothPeripheral = transmitter
        var discovered: BluetoothPeripheral?
        manager.callBackAfterDiscoveringDevice = { discovered = $0 }
        manager.didConnectTo(bluetoothTransmitter: transmitter)
        let peripheral = try XCTUnwrap(discovered)
        XCTAssertEqual(peripheral.bluetoothPeripheralType(), .M5StackType)
        XCTAssertEqual(peripheral.blePeripheral.address, address)
        XCTAssertEqual(peripheral.blePeripheral.name, "M5Stack-X")
        XCTAssertTrue(peripheral.blePeripheral.hasConnectedSinceActivation)
        XCTAssertNil(manager.callBackAfterDiscoveringDevice)
        XCTAssertTrue(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: false) === transmitter)
        XCTAssertNil(manager.currentCgmTransmitterAddress)
        manager.didConnectTo(bluetoothTransmitter: transmitter)
        XCTAssertNil(manager.tempBlueToothTransmitterWhileScanningForNewBluetoothPeripheral)
        XCTAssertEqual(manager.getBluetoothPeripherals().count, 1)
    }

    func testDidConnectToNewDexcomBecomesCurrentCGM() throws {
        let address = UUID().uuidString
        let transmitter = CGMG5Transmitter(address: address, name: "DEXCOMCV", transmitterID: "8GCOV5", bluetoothTransmitterDelegate: manager,
                                           cGMG5TransmitterDelegate: manager, cGMTransmitterDelegate: cgmRecorder, transmitterStartDate: nil,
                                           sensorStartDate: nil, activeSensorStartDate: nil, calibrationToSendToTransmitter: nil, firmware: nil,
                                           batteryLastReadDate: nil, webOOPEnabled: nil, useOtherApp: false, isAnubis: false, bluetoothSlot: .mobileApp)
        manager.tempBlueToothTransmitterWhileScanningForNewBluetoothPeripheral = transmitter
        manager.didConnectTo(bluetoothTransmitter: transmitter)
        XCTAssertEqual(manager.currentCgmTransmitterAddress, address)
        let peripheral = try XCTUnwrap(manager.getBluetoothPeripheral(for: transmitter))
        XCTAssertTrue(peripheral.blePeripheral.webOOPEnabled)
        XCTAssertTrue(transmitter.isWebOOPEnabled())
        XCTAssertTrue(manager.getCGMTransmitter() === transmitter)
        manager.deleteBluetoothPeripheral(bluetoothPeripheral: peripheral)
        XCTAssertTrue(manager.getBluetoothPeripherals().isEmpty)
        XCTAssertNil(manager.currentCgmTransmitterAddress)
    }

    func testDidConnectWithoutTemporaryTransmitterUpdatesKnownPeripheral() throws {
        let peripheral = BluetoothPeripheralType.OmniPodHeartBeatType.createNewBluetoothPeripheral(withAddress: UUID().uuidString, withName: "BOARD", nsManagedObjectContext: coreData.mainManagedObjectContext)
        insert(peripheral)
        let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: true))
        manager.didConnectTo(bluetoothTransmitter: transmitter)
        XCTAssertTrue(peripheral.blePeripheral.hasConnectedSinceActivation)
        XCTAssertNotNil(peripheral.blePeripheral.lastConnectionStatusChangeTimeStamp)
        XCTAssertNil(manager.currentCgmTransmitterAddress)
    }

    func testDexcomG5DelegateCallbacksPersistOnPeripheral() throws {
        let peripheral = try XCTUnwrap(BluetoothPeripheralType.DexcomType.createNewBluetoothPeripheral(withAddress: UUID().uuidString, withName: "DEXCOM5", nsManagedObjectContext: coreData.mainManagedObjectContext) as? DexcomG5)
        peripheral.blePeripheral.transmitterId = "8GCOV6"
        peripheral.blePeripheral.shouldconnect = false
        insert(peripheral)
        let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: true) as? CGMG5Transmitter)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        manager.received(firmware: "1.6.5.25", cGMG5Transmitter: transmitter)
        manager.received(transmitterStartDate: start, cGMG5Transmitter: transmitter)
        manager.received(sensorStartDate: start.addingTimeInterval(60), cGMG5Transmitter: transmitter)
        manager.received(sensorStatus: "OK", cGMG5Transmitter: transmitter)
        manager.received(isAnubis: true, cGMG5Transmitter: transmitter)
        manager.received(transmitterBatteryInfo: .dexcom(family: .g5, voltageA: 310, voltageB: 290, resist: 1200, runtime: 45, temperature: 28), cGMG5Transmitter: transmitter)
        manager.received(transmitterBatteryInfo: .percentage(percentage: 50), cGMG5Transmitter: transmitter)
        peripheral.resetRequired = true
        manager.reset(for: transmitter, successful: true)
        XCTAssertEqual(peripheral.firmwareVersion, "1.6.5.25")
        XCTAssertEqual(peripheral.transmitterStartDate, start)
        XCTAssertEqual(peripheral.sensorStartDate, start.addingTimeInterval(60))
        XCTAssertEqual(peripheral.sensorStatus, "OK")
        XCTAssertTrue(peripheral.isAnubis)
        XCTAssertEqual(peripheral.voltageA, 310)
        XCTAssertEqual(peripheral.voltageB, 290)
        XCTAssertEqual(peripheral.batteryResist, 1200)
        XCTAssertEqual(peripheral.batteryRuntime, 45)
        XCTAssertEqual(peripheral.batteryTemperature, 28)
        XCTAssertNotNil(peripheral.batteryLastReadDate)
        XCTAssertFalse(peripheral.resetRequired)
        XCTAssertNotNil(peripheral.lastResetTimeStamp)
    }

    func testDexcomG7DelegateCallbacksPersistOnPeripheral() throws {
        let key = UserDefaults.Key.activeSensorMaxSensorAgeInDays.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let peripheral = try XCTUnwrap(BluetoothPeripheralType.DexcomG7Type.createNewBluetoothPeripheral(withAddress: UUID().uuidString, withName: "DX01CV", nsManagedObjectContext: coreData.mainManagedObjectContext) as? DexcomG7)
        insert(peripheral)
        let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: true) as? CGMG7Transmitter)
        manager.received(sensorStartDate: Date(timeIntervalSince1970: 1_000), cGMG7Transmitter: transmitter)
        manager.received(sensorStatus: "OK / Calibrated", cGMG7Transmitter: transmitter)
        manager.received(sensorSessionLength: 1_339_200, cGMG7Transmitter: transmitter)
        manager.received(sensorSessionLength: 5, cGMG7Transmitter: transmitter)
        let version = try XCTUnwrap(DexcomG7VersionMessage(data: Data([0x4A, 0x00, 2, 18, 2, 88, 1, 0, 0, 0, 2, 0, 0, 0, 1, 2, 3, 4, 5, 6])))
        manager.received(version: version, cGMG7Transmitter: transmitter)
        let battery = try XCTUnwrap(DexcomG7BatteryStatusMessage(data: Data([0x22, 0x00, 0x3C, 0x01, 0x2C, 0x01, 0xA0, 0x05, 0x0A, 0x1E])))
        manager.received(battery: battery, readAt: Date(timeIntervalSince1970: 2_000), isFirstReading: true, cGMG7Transmitter: transmitter)
        XCTAssertEqual(peripheral.sensorStartDate, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(peripheral.sensorStatus, "OK / Calibrated")
        XCTAssertEqual(peripheral.sensorSessionLength?.doubleValue, 1_339_200)
        XCTAssertEqual(UserDefaults.standard.activeSensorMaxSensorAgeInDays, 15.5)
        XCTAssertEqual(peripheral.firmwareVersion, "2.18.2.88")
        XCTAssertEqual(peripheral.firmwareBuildVersion?.uint32Value, 1)
        XCTAssertEqual(peripheral.firmwareVersionCode?.uint32Value, 2)
        XCTAssertEqual(peripheral.voltageB, 300)
        XCTAssertEqual(peripheral.batteryRuntime, 10)
        XCTAssertEqual(peripheral.batteryLastReadDate, Date(timeIntervalSince1970: 2_000))
    }

    func testM5StackDelegateCallbacksUpdateStoredPeripheral() throws {
        let peripheral = try XCTUnwrap(BluetoothPeripheralType.M5StackType.createNewBluetoothPeripheral(withAddress: UUID().uuidString, withName: "M5", nsManagedObjectContext: coreData.mainManagedObjectContext) as? M5Stack)
        insert(peripheral)
        let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: peripheral, createANewOneIfNecesssary: true) as? M5StackBluetoothTransmitter)
        manager.receivedBattery(level: 66, m5StackBluetoothTransmitter: transmitter)
        manager.newBlePassWord(newBlePassword: "secret", m5StackBluetoothTransmitter: transmitter)
        XCTAssertEqual(peripheral.batteryLevel, 66)
        XCTAssertEqual(peripheral.blepassword, "secret")
        manager.isReadyToReceiveData(m5StackBluetoothTransmitter: transmitter)
        manager.isAskingForAllParameters(m5StackBluetoothTransmitter: transmitter)
        manager.authentication(success: true, m5StackBluetoothTransmitter: transmitter)
    }

    // MARK: - Helpers

    @discardableResult
    private func insert(_ peripheral: BluetoothPeripheral) -> Int {
        let index = manager.insertInBluetoothPeripherals(bluetoothPeripheral: peripheral)
        manager.bluetoothTransmitters.insert(nil, at: index)
        return index
    }
}
