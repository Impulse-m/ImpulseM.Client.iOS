import Foundation
import Security
import XCTest
@testable import ImpulseTransport


private let testAccessGroup: String = "test.group.impulsem"
private let otherAccessGroup: String = "other.group.impulsem"
private let legacyService: String = "telegramApplicationSecretKey_v7"


private final class MemoryKeychain: ImpulseKeychain, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var items: [String: Data] = [:]
    private var recordedServices: [String] = []
    private var recordedAccessGroups: [String] = []


    func readData(
        service: String,
        account: String,
        accessGroup: String
    ) -> Data? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return items[MemoryKeychain.key(service: service, account: account, accessGroup: accessGroup)]
    }


    func writeData(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String
    ) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        recordedServices.append(service)
        recordedAccessGroups.append(accessGroup)
        items[MemoryKeychain.key(service: service, account: account, accessGroup: accessGroup)] = data
        return true
    }


    func deleteData(
        service: String,
        account: String,
        accessGroup: String
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }
        items[MemoryKeychain.key(service: service, account: account, accessGroup: accessGroup)] = nil
    }


    func itemCount() -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return items.count
    }


    func services() -> [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedServices
    }


    func accessGroups() -> [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedAccessGroups
    }


    private static func key(
        service: String,
        account: String,
        accessGroup: String
    ) -> String {
        return service + "|" + accessGroup + "|" + account
    }
}


final class ImpulseSessionStoreTests: XCTestCase {
    func testSessionRoundTripsAllThreeFields() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )
        let tokens: ImpulseSessionTokens = ImpulseSessionTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            userId: 9_007_199_254_740_993
        )

        store.save(tokens)

        XCTAssertEqual(store.load(), tokens)
    }


    func testSaveReplacesBothTokensInOneItem() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )

        store.save(ImpulseSessionTokens(accessToken: "first-access", refreshToken: "first-refresh", userId: 7))
        store.save(ImpulseSessionTokens(accessToken: "second-access", refreshToken: "second-refresh", userId: 7))

        XCTAssertEqual(keychain.itemCount(), 1)
        XCTAssertEqual(
            store.load(),
            ImpulseSessionTokens(accessToken: "second-access", refreshToken: "second-refresh", userId: 7)
        )
    }


    func testLoggedInNeedsAccessTokenAndUserId() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )

        XCTAssertFalse(store.isLoggedIn)

        store.save(ImpulseSessionTokens(accessToken: "", refreshToken: "refresh", userId: 7))
        XCTAssertNil(store.load())
        XCTAssertFalse(store.isLoggedIn)

        store.save(ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 0))
        XCTAssertNil(store.load())
        XCTAssertFalse(store.isLoggedIn)

        store.save(ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7))
        XCTAssertTrue(store.isLoggedIn)
    }


    func testUnreadableBlobIsNotASession() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )

        _ = keychain.writeData(
            Data("not a session".utf8),
            service: ImpulseSessionStore.serviceName,
            account: "session",
            accessGroup: testAccessGroup
        )

        XCTAssertNil(store.load())
        XCTAssertFalse(store.isLoggedIn)
    }


    func testIdentityTokenIsKeptApartFromTheSession() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )
        let identity: ImpulseKeychainIdentityStore = store.identityStore()

        identity.setString("identity-jwt", forKey: ImpulseIdentityRules.storageKey)
        store.save(ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7))
        store.clear()

        XCTAssertNil(store.load())
        XCTAssertEqual(identity.string(forKey: ImpulseIdentityRules.storageKey), "identity-jwt")
    }


    func testDiscardAllClearsSessionAndIdentity() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )

        store.identityStore().setString("identity-jwt", forKey: ImpulseIdentityRules.storageKey)
        store.save(ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7))
        store.discardAll()

        XCTAssertNil(store.load())
        XCTAssertNil(store.identityStore().string(forKey: ImpulseIdentityRules.storageKey))
        XCTAssertEqual(keychain.itemCount(), 0)
    }


    func testEmptyIdentityTokenReadsAsAbsent() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )

        store.identityStore().setString("", forKey: ImpulseIdentityRules.storageKey)

        XCTAssertNil(store.identityStore().string(forKey: ImpulseIdentityRules.storageKey))
    }


    func testItemsUseTheFamilyServiceAndTheExplicitAccessGroup() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )

        store.save(ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7))
        store.identityStore().setString("identity-jwt", forKey: ImpulseIdentityRules.storageKey)

        XCTAssertEqual(ImpulseSessionStore.serviceName, "impulsemApplicationSecretKey_v1")
        XCTAssertEqual(keychain.services(), [ImpulseSessionStore.serviceName, ImpulseSessionStore.serviceName])
        XCTAssertEqual(keychain.accessGroups(), [testAccessGroup, testAccessGroup])
    }


    func testNewItemsAreThisDeviceOnlyAndExcludedFromBackups() {
        let query: [String: Any] = ImpulseKeychainQuery.addition(
            service: ImpulseSessionStore.serviceName,
            account: "session",
            accessGroup: testAccessGroup,
            data: Data()
        )

        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, testAccessGroup)
        XCTAssertEqual(query[kSecAttrService as String] as? String, ImpulseSessionStore.serviceName)
    }


    func testAccountIndexesKeepSessionsApart() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let first: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )
        let second: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 1,
            accessGroup: testAccessGroup,
            keychain: keychain
        )

        first.save(ImpulseSessionTokens(accessToken: "first", refreshToken: "refresh", userId: 7))

        XCTAssertNil(second.load())
        XCTAssertEqual(first.load()?.accessToken, "first")
    }


    func testOtherAccessGroupDoesNotSeeTheSession() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let writer: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )
        let reader: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: otherAccessGroup,
            keychain: keychain
        )

        writer.save(ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7))

        XCTAssertNil(reader.load())
    }


    func testLegacyTelegramItemsAreNotMigrated() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )
        let legacyTokens: Data = Data("{\"accessToken\":\"a\",\"refreshToken\":\"r\",\"userId\":7}".utf8)

        _ = keychain.writeData(
            legacyTokens,
            service: legacyService,
            account: "session",
            accessGroup: testAccessGroup
        )

        XCTAssertNil(store.load())
        XCTAssertFalse(store.isLoggedIn)
    }
}
