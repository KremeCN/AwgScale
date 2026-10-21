import Foundation
import Security
import XCTest
@testable import AwgScale

final class KeychainPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "AwgScale.KeychainTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testFailedReplacementPreservesExistingMachineKey() throws {
        let security = FakeKeychain()
        security.values["shared"] = Data("old-machine-key".utf8)
        security.writeErrors["shared"] = errSecInteractionNotAllowed
        let store = makeStore(security, groups: ["shared"])

        XCTAssertThrowsError(try store.write("statestore-_machinekey", value: "replacement"))
        XCTAssertEqual(security.values["shared"], Data("old-machine-key".utf8))
        XCTAssertNil(defaults.object(forKey: "statestore-_machinekey"))
    }

    func testUnavailableGroupDoesNotHideRealWriteFailure() throws {
        let security = FakeKeychain()
        security.missingGroups.insert("unavailable")
        security.values["shared"] = Data("old".utf8)
        security.writeErrors["shared"] = errSecInteractionNotAllowed
        let store = makeStore(security, groups: ["unavailable", "shared"])

        XCTAssertThrowsError(try store.write("statestore-_machinekey", value: "new"))
        XCTAssertNil(defaults.object(forKey: "statestore-_machinekey"))
        XCTAssertEqual(security.values["shared"], Data("old".utf8))
    }

    func testLockedKeychainIsNotReportedAsMissingState() throws {
        let security = FakeKeychain()
        security.readErrors["shared"] = errSecInteractionNotAllowed
        let store = makeStore(security, groups: ["shared", nil])

        XCTAssertThrowsError(try store.read("statestore-_machinekey")) { error in
            XCTAssertEqual((error as NSError).code, Int(errSecInteractionNotAllowed))
        }
    }

    func testLockedKeychainDoesNotReturnStalePlaintextFallback() throws {
        let security = FakeKeychain()
        security.readErrors["shared"] = errSecInteractionNotAllowed
        defaults.set("stale", forKey: "statestore-_machinekey")
        let store = makeStore(security, groups: ["shared"])

        XCTAssertThrowsError(try store.read("statestore-_machinekey"))
    }

    func testSuccessfulUpdateRemovesLegacyPlaintextCopy() throws {
        let security = FakeKeychain()
        security.values["shared"] = Data("old".utf8)
        defaults.set("old", forKey: "statestore-_machinekey")
        let store = makeStore(security, groups: ["shared"])

        try store.write("statestore-_machinekey", value: "new")
        XCTAssertEqual(try store.read("statestore-_machinekey"), "new")
        XCTAssertNil(defaults.object(forKey: "statestore-_machinekey"))
    }

    func testConcurrentInsertStillUpdatesTheSameKeychainGroup() throws {
        let security = FakeKeychain()
        security.insertBeforeAdd = true
        let store = makeStore(security, groups: ["shared"])

        try store.write("statestore-_machinekey", value: "new")
        XCTAssertEqual(security.values["shared"], Data("new".utf8))
    }

    func testMissingEntitlementsRetainExistingFallbackMode() throws {
        let security = FakeKeychain()
        security.missingGroups = ["shared", "default"]
        let store = makeStore(security, groups: ["shared", nil])

        try store.write("statestore-_machinekey", value: "fallback")
        XCTAssertEqual(try store.read("statestore-_machinekey"), "fallback")
    }

    func testAbsentStateRemainsAbsent() throws {
        let security = FakeKeychain()
        XCTAssertEqual(try makeStore(security, groups: ["shared"]).read("missing"), "")
    }

    private func makeStore(_ security: FakeKeychain, groups: [String?]) -> KeychainPreferences {
        KeychainPreferences(groups: groups, fallback: defaults,
                            update: security.update, add: security.add, copy: security.copy)
    }
}

private final class FakeKeychain {
    var values: [String: Data] = [:]
    var missingGroups: Set<String> = []
    var readErrors: [String: OSStatus] = [:]
    var writeErrors: [String: OSStatus] = [:]
    var insertBeforeAdd = false

    private func group(_ query: CFDictionary) -> String {
        (query as NSDictionary)[kSecAttrAccessGroup] as? String ?? "default"
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        let g = group(query)
        if missingGroups.contains(g) { return errSecMissingEntitlement }
        if let error = writeErrors[g] { return error }
        guard values[g] != nil else { return errSecItemNotFound }
        values[g] = (attributes as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
    }

    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let g = group(query)
        if missingGroups.contains(g) { return errSecMissingEntitlement }
        if let error = writeErrors[g] { return error }
        if insertBeforeAdd { values[g] = Data("concurrent".utf8); insertBeforeAdd = false }
        if values[g] != nil { return errSecDuplicateItem }
        values[g] = (query as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
    }

    func copy(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let g = group(query)
        if missingGroups.contains(g) { return errSecMissingEntitlement }
        if let error = readErrors[g] { return error }
        guard let value = values[g] else { return errSecItemNotFound }
        result?.pointee = value as CFData
        return errSecSuccess
    }

}
