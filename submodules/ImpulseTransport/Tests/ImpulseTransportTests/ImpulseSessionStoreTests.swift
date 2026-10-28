import Foundation
import Security
import XCTest
@testable import ImpulseTransport


private let testAccessGroup: String = "test.group.impulsem"
private let otherAccessGroup: String = "other.group.impulsem"
private let legacyService: String = "telegramApplicationSecretKey_v7"


/// An in-memory keychain. With a refused status, every call that names an access group fails with that status, the way
/// an unsigned build answers errSecMissingEntitlement.
private final class MemoryKeychain: ImpulseKeychain, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let refusedAccessGroupStatus: OSStatus?
    private var items: [String: Data] = [:]
    private var writtenServices: [String] = []
    private var writtenAccessGroups: [String?] = []
    private var attemptedAccessGroups: [String?] = []


    init(refusedAccessGroupStatus: OSStatus? = nil) {
        self.refusedAccessGroupStatus = refusedAccessGroupStatus
    }


    func readData(
        service: String,
        account: String,
        accessGroup: String?
    ) throws -> Data? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.attemptedAccessGroups.append(accessGroup)
        try self.refuseIfNeeded(accessGroup: accessGroup)
        return self.items[MemoryKeychain.key(service: service, account: account, accessGroup: accessGroup)]
    }


    func writeData(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.attemptedAccessGroups.append(accessGroup)
        try self.refuseIfNeeded(accessGroup: accessGroup)
        self.writtenServices.append(service)
        self.writtenAccessGroups.append(accessGroup)
        self.items[MemoryKeychain.key(service: service, account: account, accessGroup: accessGroup)] = data
    }


    func deleteData(
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.attemptedAccessGroups.append(accessGroup)
        try self.refuseIfNeeded(accessGroup: accessGroup)
        self.items[MemoryKeychain.key(service: service, account: account, accessGroup: accessGroup)] = nil
    }


    func itemCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.items.count
    }


    func services() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.writtenServices
    }


    func writeAccessGroups() -> [String?] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.writtenAccessGroups
    }


    func attemptedGroups() -> [String?] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.attemptedAccessGroups
    }


    private func refuseIfNeeded(accessGroup: String?) throws {
        guard let status: OSStatus = self.refusedAccessGroupStatus, accessGroup != nil else {
            return
        }
        throw ImpulseKeychainError(status: status)
    }


    private static func key(
        service: String,
        account: String,
        accessGroup: String?
    ) -> String {
        return service + "|" + (accessGroup ?? "<own items>") + "|" + account
    }
}


/// Collects the messages the fallback announces.
private final class NoticeRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var messages: [String] = []


    func record(_ message: String) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.messages.append(message)
    }


    func count() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.messages.count
    }
}


final class ImpulseSessionStoreTests: XCTestCase {
    private func makeNotice(_ recorder: NoticeRecorder) -> ImpulseKeychainFallbackNotice {
        return ImpulseKeychainFallbackNotice(sink: { (message: String) -> Void in
            recorder.record(message)
        })
    }


    private func makeStore(
        keychain: MemoryKeychain,
        recorder: NoticeRecorder
    ) -> ImpulseSessionStore {
        return ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain,
            notice: self.makeNotice(recorder)
        )
    }


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


    func testUnreadableBlobIsNotASession() throws {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )

        try keychain.writeData(
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

        let expectedGroups: [String?] = [testAccessGroup, testAccessGroup]
        XCTAssertEqual(ImpulseSessionStore.serviceName, "impulsemApplicationSecretKey_v1")
        XCTAssertEqual(keychain.services(), [ImpulseSessionStore.serviceName, ImpulseSessionStore.serviceName])
        XCTAssertEqual(keychain.writeAccessGroups(), expectedGroups)
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


    func testLegacyTelegramItemsAreNotMigrated() throws {
        let keychain: MemoryKeychain = MemoryKeychain()
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: testAccessGroup,
            keychain: keychain
        )
        let legacyTokens: Data = Data("{\"accessToken\":\"a\",\"refreshToken\":\"r\",\"userId\":7}".utf8)

        try keychain.writeData(
            legacyTokens,
            service: legacyService,
            account: "session",
            accessGroup: testAccessGroup
        )

        XCTAssertNil(store.load())
        XCTAssertFalse(store.isLoggedIn)
    }


    func testSignedBuildKeepsTheAccessGroupAndSaysNothing() {
        let keychain: MemoryKeychain = MemoryKeychain()
        let recorder: NoticeRecorder = NoticeRecorder()
        let store: ImpulseSessionStore = self.makeStore(keychain: keychain, recorder: recorder)
        let tokens: ImpulseSessionTokens = ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7)

        store.save(tokens)

        XCTAssertEqual(store.load(), tokens)
        let expectedGroups: [String?] = [testAccessGroup]
        XCTAssertEqual(keychain.writeAccessGroups(), expectedGroups)
        XCTAssertFalse(keychain.attemptedGroups().contains(where: { (group: String?) -> Bool in group == nil }))
        XCTAssertEqual(recorder.count(), 0)
    }


    func testMissingEntitlementFallsBackToTheOwnItems() {
        let keychain: MemoryKeychain = MemoryKeychain(refusedAccessGroupStatus: errSecMissingEntitlement)
        let recorder: NoticeRecorder = NoticeRecorder()
        let store: ImpulseSessionStore = self.makeStore(keychain: keychain, recorder: recorder)
        let tokens: ImpulseSessionTokens = ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7)

        store.save(tokens)

        XCTAssertEqual(store.load(), tokens)
        XCTAssertTrue(store.isLoggedIn)
        XCTAssertEqual(keychain.itemCount(), 1)
        let expectedGroups: [String?] = [nil]
        XCTAssertEqual(keychain.writeAccessGroups(), expectedGroups)
    }


    func testFallbackIsAnnouncedOnceAndStaysOnTheOwnItems() {
        let keychain: MemoryKeychain = MemoryKeychain(refusedAccessGroupStatus: errSecMissingEntitlement)
        let recorder: NoticeRecorder = NoticeRecorder()
        let store: ImpulseSessionStore = self.makeStore(keychain: keychain, recorder: recorder)

        store.save(ImpulseSessionTokens(accessToken: "first", refreshToken: "refresh", userId: 7))
        store.save(ImpulseSessionTokens(accessToken: "second", refreshToken: "refresh", userId: 7))
        XCTAssertEqual(store.load()?.accessToken, "second")
        store.clear()
        store.save(ImpulseSessionTokens(accessToken: "third", refreshToken: "refresh", userId: 7))

        XCTAssertEqual(recorder.count(), 1)
        let refusedAttempts: Int = keychain.attemptedGroups().filter({ (group: String?) -> Bool in
            group == testAccessGroup
        }).count
        XCTAssertEqual(refusedAttempts, 1)
        XCTAssertEqual(store.load()?.accessToken, "third")
    }


    func testFallbackKeepsTheIdentityTokenWorking() {
        let keychain: MemoryKeychain = MemoryKeychain(refusedAccessGroupStatus: errSecMissingEntitlement)
        let recorder: NoticeRecorder = NoticeRecorder()
        let store: ImpulseSessionStore = self.makeStore(keychain: keychain, recorder: recorder)

        store.identityStore().setString("identity-jwt", forKey: ImpulseIdentityRules.storageKey)

        XCTAssertEqual(store.identityStore().string(forKey: ImpulseIdentityRules.storageKey), "identity-jwt")
        XCTAssertEqual(recorder.count(), 1)
    }


    func testFallbackDiscardAllRemovesTheOwnItems() {
        let keychain: MemoryKeychain = MemoryKeychain(refusedAccessGroupStatus: errSecMissingEntitlement)
        let recorder: NoticeRecorder = NoticeRecorder()
        let store: ImpulseSessionStore = self.makeStore(keychain: keychain, recorder: recorder)

        store.identityStore().setString("identity-jwt", forKey: ImpulseIdentityRules.storageKey)
        store.save(ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7))
        store.discardAll()

        XCTAssertNil(store.load())
        XCTAssertNil(store.identityStore().string(forKey: ImpulseIdentityRules.storageKey))
        XCTAssertEqual(keychain.itemCount(), 0)
    }


    func testOtherRefusalsDoNotFallBack() {
        let keychain: MemoryKeychain = MemoryKeychain(refusedAccessGroupStatus: errSecInteractionNotAllowed)
        let recorder: NoticeRecorder = NoticeRecorder()
        let store: ImpulseSessionStore = self.makeStore(keychain: keychain, recorder: recorder)

        store.save(ImpulseSessionTokens(accessToken: "access", refreshToken: "refresh", userId: 7))

        XCTAssertNil(store.load())
        XCTAssertFalse(store.isLoggedIn)
        XCTAssertEqual(keychain.itemCount(), 0)
        XCTAssertEqual(recorder.count(), 0)
        XCTAssertFalse(keychain.attemptedGroups().contains(where: { (group: String?) -> Bool in group == nil }))
    }
}
