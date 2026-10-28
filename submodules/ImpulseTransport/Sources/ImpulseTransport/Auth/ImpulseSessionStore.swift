import Foundation
import os
import Security


/// A keychain call that the system refused, with the status it returned.
public struct ImpulseKeychainError: Error, Equatable, Sendable {
    public let status: OSStatus


    public init(status: OSStatus) {
        self.status = status
    }
}


/// A generic-password store that holds the items of the ImpulseM session. The system keychain and an in-memory double
/// both implement it. A nil access group addresses the app's own items, which carry no access group.
public protocol ImpulseKeychain: Sendable {
    /// Returns the stored data of one item, or nil when no item matches. Throws when the system refuses the call.
    func readData(
        service: String,
        account: String,
        accessGroup: String?
    ) throws -> Data?

    /// Stores the data of one item, replacing an earlier value. Throws when the write failed.
    func writeData(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?
    ) throws

    /// Removes one item. Removing a missing item does nothing. Throws when the system refuses the call.
    func deleteData(
        service: String,
        account: String,
        accessGroup: String?
    ) throws
}


/// The query dictionaries of the system keychain, kept apart so the attributes can be checked without a keychain.
enum ImpulseKeychainQuery {
    static func item(
        service: String,
        account: String,
        accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [:]
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        if let accessGroup: String = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }


    /// A new item is readable after the first unlock and never leaves this device: it is excluded from backups.
    static func addition(
        service: String,
        account: String,
        accessGroup: String?,
        data: Data
    ) -> [String: Any] {
        var query: [String: Any] = item(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }
}


/// The system keychain. Items are written with an explicit access group, so an installed official Telegram cannot read
/// them. A nil access group addresses the app's own items.
public struct ImpulseSystemKeychain: ImpulseKeychain {
    public init() {
    }


    public func readData(
        service: String,
        account: String,
        accessGroup: String?
    ) throws -> Data? {
        var query: [String: Any] = ImpulseKeychainQuery.item(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ImpulseKeychainError(status: status)
        }
        return result as? Data
    }


    public func writeData(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus: OSStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ImpulseKeychainError(status: updateStatus)
        }
        let addQuery: [String: Any] = ImpulseKeychainQuery.addition(
            service: service,
            account: account,
            accessGroup: accessGroup,
            data: data
        )
        let addStatus: OSStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ImpulseKeychainError(status: addStatus)
        }
    }


    public func deleteData(
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        let status: OSStatus = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ImpulseKeychainError(status: status)
        }
    }
}


/// Says once that the session is kept in the app's own keychain items. The message goes to a sink, so the single
/// announcement can be checked.
final class ImpulseKeychainFallbackNotice: @unchecked Sendable {
    static let shared: ImpulseKeychainFallbackNotice = ImpulseKeychainFallbackNotice(sink: { (message: String) -> Void in
        ImpulseKeychainFallbackNotice.logger.notice("\(message, privacy: .public)")
    })

    private static let logger: Logger = Logger(subsystem: "ImpulseTransport", category: "ImpulseKeychain")
    private static let message: String = "The keychain refused the access group (errSecMissingEntitlement). The session is kept in the app's own keychain items without an access group, so the share extension cannot read it."

    private let lock: NSLock = NSLock()
    private let sink: @Sendable (String) -> Void
    private var announced: Bool = false


    init(sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }


    func announceOnce() {
        self.lock.lock()
        let isFirst: Bool = !self.announced
        self.announced = true
        self.lock.unlock()
        if isFirst {
            self.sink(ImpulseKeychainFallbackNotice.message)
        }
    }
}


/// Runs keychain calls for one store. The calls use the access group. Only when the system answers
/// errSecMissingEntitlement does the store move to the app's own items, announce it once, and stay there.
final class ImpulseKeychainAccess: @unchecked Sendable {
    private let keychain: any ImpulseKeychain
    private let accessGroup: String
    private let notice: ImpulseKeychainFallbackNotice
    private let lock: NSLock = NSLock()
    private var fellBack: Bool = false


    init(
        keychain: any ImpulseKeychain,
        accessGroup: String,
        notice: ImpulseKeychainFallbackNotice
    ) {
        self.keychain = keychain
        self.accessGroup = accessGroup
        self.notice = notice
    }


    /// Runs one keychain call. A call that fails for any other reason gives the fallback value.
    func run<Output>(
        fallback: Output,
        _ operation: (any ImpulseKeychain, String?) throws -> Output
    ) -> Output {
        let group: String? = self.currentAccessGroup()
        do {
            return try operation(self.keychain, group)
        } catch let error as ImpulseKeychainError where error.status == errSecMissingEntitlement && group != nil {
            self.switchToOwnItems()
            do {
                return try operation(self.keychain, nil)
            } catch {
                return fallback
            }
        } catch {
            return fallback
        }
    }


    private func currentAccessGroup() -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.fellBack ? nil : self.accessGroup
    }


    private func switchToOwnItems() {
        self.lock.lock()
        self.fellBack = true
        self.lock.unlock()
        self.notice.announceOnce()
    }
}


/// The session blob as it is written to the keychain. Both tokens and the user id go in one item, so one write replaces
/// them together.
private struct ImpulseStoredSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let userId: Int64
}


/// Reads and writes the connection identity token as one keychain item per account, apart from the session blob.
public struct ImpulseKeychainIdentityStore: ImpulseIdentityStore {
    private let access: ImpulseKeychainAccess
    private let accountSuffix: String


    public init(
        keychain: any ImpulseKeychain,
        accessGroup: String,
        accountSuffix: String
    ) {
        self.access = ImpulseKeychainAccess(
            keychain: keychain,
            accessGroup: accessGroup,
            notice: ImpulseKeychainFallbackNotice.shared
        )
        self.accountSuffix = accountSuffix
    }


    init(
        access: ImpulseKeychainAccess,
        accountSuffix: String
    ) {
        self.access = access
        self.accountSuffix = accountSuffix
    }


    public func string(forKey key: String) -> String? {
        let account: String = key + self.accountSuffix
        let data: Data? = self.access.run(fallback: nil) { (keychain: any ImpulseKeychain, group: String?) throws -> Data? in
            return try keychain.readData(
                service: ImpulseSessionStore.serviceName,
                account: account,
                accessGroup: group
            )
        }
        guard let value: Data = data else {
            return nil
        }
        guard let text: String = String(data: value, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        return text
    }


    public func setString(
        _ value: String,
        forKey key: String
    ) {
        guard let data: Data = value.data(using: .utf8) else {
            return
        }
        let account: String = key + self.accountSuffix
        self.access.run(fallback: ()) { (keychain: any ImpulseKeychain, group: String?) throws -> Void in
            try keychain.writeData(
                data,
                service: ImpulseSessionStore.serviceName,
                account: account,
                accessGroup: group
            )
        }
    }


    public func removeValue(forKey key: String) {
        let account: String = key + self.accountSuffix
        self.access.run(fallback: ()) { (keychain: any ImpulseKeychain, group: String?) throws -> Void in
            try keychain.deleteData(
                service: ImpulseSessionStore.serviceName,
                account: account,
                accessGroup: group
            )
        }
    }
}


/// Keeps one account's ImpulseM session tokens in the keychain. The session is logged in when the stored blob has an
/// access token and a user id.
public struct ImpulseSessionStore: ImpulseSessionStorage {
    /// The keychain service of every ImpulseM item. It is the tag family of the ImpulseM keychain items.
    public static let serviceName: String = "impulsemApplicationSecretKey_v1"

    /// True when a session is stored: the stored blob has an access token and a non-zero user id.
    public var isLoggedIn: Bool {
        return load() != nil
    }


    private let access: ImpulseKeychainAccess
    private let accountSuffix: String
    private let sessionAccount: String


    /// The account index mirrors the account slot of the app: index 0 keeps the plain names.
    public init(
        accountIndex: Int,
        accessGroup: String,
        keychain: any ImpulseKeychain = ImpulseSystemKeychain()
    ) {
        self.init(
            accountIndex: accountIndex,
            accessGroup: accessGroup,
            keychain: keychain,
            notice: ImpulseKeychainFallbackNotice.shared
        )
    }


    init(
        accountIndex: Int,
        accessGroup: String,
        keychain: any ImpulseKeychain,
        notice: ImpulseKeychainFallbackNotice
    ) {
        let suffix: String = accountIndex == 0 ? "" : String(accountIndex)
        self.access = ImpulseKeychainAccess(
            keychain: keychain,
            accessGroup: accessGroup,
            notice: notice
        )
        self.accountSuffix = suffix
        self.sessionAccount = "session" + suffix
    }


    /// Returns nil when no session is stored, or when the stored blob is unreadable or incomplete.
    public func load() -> ImpulseSessionTokens? {
        let account: String = self.sessionAccount
        let data: Data? = self.access.run(fallback: nil) { (keychain: any ImpulseKeychain, group: String?) throws -> Data? in
            return try keychain.readData(
                service: ImpulseSessionStore.serviceName,
                account: account,
                accessGroup: group
            )
        }
        guard let blob: Data = data else {
            return nil
        }
        guard let stored: ImpulseStoredSession = try? JSONDecoder().decode(ImpulseStoredSession.self, from: blob) else {
            return nil
        }
        guard !stored.accessToken.isEmpty, stored.userId != 0 else {
            return nil
        }
        return ImpulseSessionTokens(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            userId: stored.userId
        )
    }


    /// Replaces the stored session in one keychain write. A failed write keeps the earlier session.
    public func save(_ tokens: ImpulseSessionTokens) {
        let stored: ImpulseStoredSession = ImpulseStoredSession(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            userId: tokens.userId
        )
        guard let data: Data = try? JSONEncoder().encode(stored) else {
            return
        }
        let account: String = self.sessionAccount
        self.access.run(fallback: ()) { (keychain: any ImpulseKeychain, group: String?) throws -> Void in
            try keychain.writeData(
                data,
                service: ImpulseSessionStore.serviceName,
                account: account,
                accessGroup: group
            )
        }
    }


    /// Removes the session tokens. The identity token is kept, as the identity is minted before a login.
    public func clear() {
        let account: String = self.sessionAccount
        self.access.run(fallback: ()) { (keychain: any ImpulseKeychain, group: String?) throws -> Void in
            try keychain.deleteData(
                service: ImpulseSessionStore.serviceName,
                account: account,
                accessGroup: group
            )
        }
    }


    /// Removes the session tokens and the identity token: the sign-out discard.
    public func discardAll() {
        clear()
        identityStore().removeValue(forKey: ImpulseIdentityRules.storageKey)
    }


    /// The store of the identity token of this account.
    public func identityStore() -> ImpulseKeychainIdentityStore {
        return ImpulseKeychainIdentityStore(
            access: self.access,
            accountSuffix: self.accountSuffix
        )
    }
}
