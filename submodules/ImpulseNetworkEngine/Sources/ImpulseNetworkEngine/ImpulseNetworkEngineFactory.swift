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
    private let routeSource: ImpulseProxyRouteSource?


    /// The engine connects directly unless a route source is given; the transport reads the route for each new connection.
    public init(proxyRouteSource: ImpulseProxyRouteSource? = nil) {
        self.keychain = ImpulseSystemKeychain()
        self.keychainAccessGroup = nil
        self.baseUrl = ImpulseEndpoints.productionBaseUrl
        self.routeSource = proxyRouteSource
    }


    init(
        keychain: any ImpulseKeychain,
        keychainAccessGroup: String?,
        baseUrl: String,
        proxyRouteSource: ImpulseProxyRouteSource? = nil
    ) {
        self.keychain = keychain
        self.keychainAccessGroup = keychainAccessGroup
        self.baseUrl = baseUrl
        self.routeSource = proxyRouteSource
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
            let inputs: ImpulseNetworkCompositionInputs = try self.makeCompositionInputs(context: context)
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


    /// The inputs of the composition root for one context: the endpoints, the bundled mapping, the keychain, the declaration,
    /// the update bridge of the context, and the route source the transport reads for each new connection.
    func makeCompositionInputs(context: MTContext) throws -> ImpulseNetworkCompositionInputs {
        return ImpulseNetworkCompositionInputs(
            endpoints: try ImpulseEndpoints(baseUrl: self.baseUrl),
            mapping: try ImpulseMapping.loadBundled(),
            keychain: self.keychain,
            keychainAccessGroup: self.resolvedAccessGroup(),
            identityClock: ImpulseSystemClock(),
            identityScheduler: ImpulseTaskScheduler(),
            declaration: ImpulseNetworkEngineFactory.makeDeclaration(),
            updateBridge: ImpulseUpdateBridge(context: context),
            routeSource: self.routeSource
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


    /// The keychain access group the session items are written to: the given one, else the one the bundle names. When
    /// neither names one, the group is nil, so the items go to the default group of the app.
    private func resolvedAccessGroup() -> String? {
        if let group: String = ImpulseNetworkEngineFactory.normalizedAccessGroup(self.keychainAccessGroup) {
            return group
        }

        let bundled: Any? = Bundle.main.object(forInfoDictionaryKey: ImpulseNetworkEngineFactory.keychainAccessGroupKey)
        if let value: String = ImpulseNetworkEngineFactory.normalizedAccessGroup(bundled as? String) {
            return value
        }

        Logger.shared.log("ImpulseNetwork", "The bundle names no keychain access group, so the default group is used")
        return nil
    }


    /// An access group as the keychain takes it: nil when none is named. An empty name is no name, so it never reaches the
    /// keychain query as a group that matches nothing.
    static func normalizedAccessGroup(_ value: String?) -> String? {
        guard let group: String = value, !group.isEmpty else {
            return nil
        }

        return group
    }
}
