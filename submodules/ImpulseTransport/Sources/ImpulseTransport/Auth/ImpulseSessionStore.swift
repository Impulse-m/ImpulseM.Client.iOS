import Foundation
import Security


/// A generic-password store that holds the items of the ImpulseM session. The system keychain and an in-memory double
/// both implement it.
public protocol ImpulseKeychain: Sendable {
    /// Returns the stored data of one item, or nil when no item matches.
    func readData(
        service: String,
        account: String,
        accessGroup: String
    ) -> Data?

    /// Stores the data of one item, replacing an earlier value. Returns false when the write failed.
    func writeData(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String
    ) -> Bool

    /// Removes one item. Removing a missing item does nothing.
    func deleteData(
        service: String,
        account: String,
        accessGroup: String
    )
}


/// The query dictionaries of the system keychain, kept apart so the attributes can be checked without a keychain.
enum ImpulseKeychainQuery {
    static func item(
        service: String,
        account: String,
        accessGroup: String
    ) -> [String: Any] {
        var query: [String: Any] = [:]
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        query[kSecAttrAccessGroup as String] = accessGroup
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }


    /// A new item is readable after the first unlock and never leaves this device: it is excluded from backups.
    static func addition(
        service: String,
        account: String,
        accessGroup: String,
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
/// them.
public struct ImpulseSystemKeychain: ImpulseKeychain {
    public init() {
    }


    public func readData(
        service: String,
        account: String,
        accessGroup: String
    ) -> Data? {
        var query: [String: Any] = ImpulseKeychainQuery.item(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }
        return result as? Data
    }


    public func writeData(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String
    ) -> Bool {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus: OSStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }
        let addQuery: [String: Any] = ImpulseKeychainQuery.addition(
            service: service,
            account: account,
            accessGroup: accessGroup,
            data: data
        )
        let addStatus: OSStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }


    public func deleteData(
        service: String,
        account: String,
        accessGroup: String
    ) {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        _ = SecItemDelete(query as CFDictionary)
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
    private let keychain: any ImpulseKeychain
    private let accessGroup: String
    private let accountSuffix: String


    public init(
        keychain: any ImpulseKeychain,
        accessGroup: String,
        accountSuffix: String
    ) {
        self.keychain = keychain
        self.accessGroup = accessGroup
        self.accountSuffix = accountSuffix
    }


    public func string(forKey key: String) -> String? {
        guard let data: Data = keychain.readData(
            service: ImpulseSessionStore.serviceName,
            account: key + accountSuffix,
            accessGroup: accessGroup
        ) else {
            return nil
        }
        guard let text: String = String(data: data, encoding: .utf8), !text.isEmpty else {
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
        _ = keychain.writeData(
            data,
            service: ImpulseSessionStore.serviceName,
            account: key + accountSuffix,
            accessGroup: accessGroup
        )
    }


    public func removeValue(forKey key: String) {
        keychain.deleteData(
            service: ImpulseSessionStore.serviceName,
            account: key + accountSuffix,
            accessGroup: accessGroup
        )
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


    private let keychain: any ImpulseKeychain
    private let accessGroup: String
    private let accountSuffix: String
    private let sessionAccount: String


    /// The account index mirrors the account slot of the app: index 0 keeps the plain names.
    public init(
        accountIndex: Int,
        accessGroup: String,
        keychain: any ImpulseKeychain = ImpulseSystemKeychain()
    ) {
        let suffix: String = accountIndex == 0 ? "" : String(accountIndex)
        self.keychain = keychain
        self.accessGroup = accessGroup
        self.accountSuffix = suffix
        self.sessionAccount = "session" + suffix
    }


    /// Returns nil when no session is stored, or when the stored blob is unreadable or incomplete.
    public func load() -> ImpulseSessionTokens? {
        guard let data: Data = keychain.readData(
            service: ImpulseSessionStore.serviceName,
            account: sessionAccount,
            accessGroup: accessGroup
        ) else {
            return nil
        }
        guard let stored: ImpulseStoredSession = try? JSONDecoder().decode(ImpulseStoredSession.self, from: data) else {
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
        _ = keychain.writeData(
            data,
            service: ImpulseSessionStore.serviceName,
            account: sessionAccount,
            accessGroup: accessGroup
        )
    }


    /// Removes the session tokens. The identity token is kept, as the identity is minted before a login.
    public func clear() {
        keychain.deleteData(
            service: ImpulseSessionStore.serviceName,
            account: sessionAccount,
            accessGroup: accessGroup
        )
    }


    /// Removes the session tokens and the identity token: the sign-out discard.
    public func discardAll() {
        clear()
        identityStore().removeValue(forKey: ImpulseIdentityRules.storageKey)
    }


    /// The store of the identity token of this account.
    public func identityStore() -> ImpulseKeychainIdentityStore {
        return ImpulseKeychainIdentityStore(
            keychain: keychain,
            accessGroup: accessGroup,
            accountSuffix: accountSuffix
        )
    }
}
