import Foundation
import MtProtoKit
import TelegramCore
import ImpulseTransport


/// Supplies the ImpulseM network engine to `NetworkInitializationArguments`. The factory never declines: the engine serves
/// the application and its app extensions alike, so `makeEngine` never returns nil for a context.
public struct ImpulseNetworkEngineFactory: NetworkEngineFactory {
    /// The key of the bundle's Info dictionary that names the keychain access group of the session items.
    public static let keychainAccessGroupKey: String = "ImpulseKeychainAccessGroup"

    private let keychain: any ImpulseKeychain
    private let keychainAccessGroup: String?
    private let baseUrl: String


    public init() {
        self.keychain = ImpulseSystemKeychain()
        self.keychainAccessGroup = nil
        self.baseUrl = ImpulseEndpoints.productionBaseUrl
    }


    init(
        keychain: any ImpulseKeychain,
        keychainAccessGroup: String?,
        baseUrl: String
    ) {
        self.keychain = keychain
        self.keychainAccessGroup = keychainAccessGroup
        self.baseUrl = baseUrl
    }


    public var supportsWebProxy: Bool {
        return false
    }


    public func makeEngine(
        context: MTContext,
        isAppExtension: Bool
    ) -> NetworkEngine? {
        Logger.shared.log("ImpulseNetwork", "The engine is created (app extension: \(isAppExtension))")

        let root: ImpulseNetworkCompositionRoot
        do {
            let inputs: ImpulseNetworkCompositionInputs = ImpulseNetworkCompositionInputs(
                endpoints: try ImpulseEndpoints(baseUrl: self.baseUrl),
                mapping: try ImpulseMapping.loadBundled(),
                keychain: self.keychain,
                keychainAccessGroup: self.resolvedAccessGroup(),
                identityClock: ImpulseSystemClock(),
                identityScheduler: ImpulseTaskScheduler(),
                declaration: ImpulseNetworkEngineFactory.makeDeclaration(),
                updateBridge: ImpulseUpdateBridge(context: context)
            )
            root = try ImpulseNetworkCompositionRoot(inputs: inputs)
        } catch {
            preconditionFailure("The ImpulseM network cannot be composed: \(error)")
        }

        return ImpulseNetworkEngine(
            context: context,
            sessionBuilder: { datacenterId, role, _, delegate in
                return root.makeSession(datacenterId: datacenterId, role: role, delegate: delegate)
            },
            lifecycle: root
        )
    }


    /// The declaration of this application and device: the api id, the device, the system and application versions and the languages.
    static func makeDeclaration() -> ImpulseDeclaration {
        let appVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let language: String = Locale.current.languageCode ?? "en"
        return ImpulseDeclaration(
            apiId: 4,
            deviceModel: "Mac",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion,
            systemLangCode: language,
            langPack: ImpulseDeclaration.macosLangPack,
            langCode: language
        )
    }


    /// The keychain access group the session items are written to: the given one, else the one the bundle names. A bundle
    /// that names none gets an empty group, and the session items cannot be stored; the engine still runs.
    private func resolvedAccessGroup() -> String {
        if let group: String = self.keychainAccessGroup {
            return group
        }

        let bundled: Any? = Bundle.main.object(forInfoDictionaryKey: ImpulseNetworkEngineFactory.keychainAccessGroupKey)
        if let value: String = bundled as? String, !value.isEmpty {
            return value
        }

        Logger.shared.log("ImpulseNetwork", "The bundle names no keychain access group, so the session cannot be stored")
        return ""
    }
}
