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
    private let baseUrl: String?
    private let routeSource: ImpulseProxyRouteSource?


    /// The engine connects directly unless a route source is given; the transport reads the route for each new connection.
    /// The base URL is the RPC host of the backend; the app takes it from its build configuration. A nil, empty or invalid
    /// base URL makes the factory produce an unconfigured engine, which never connects.
    public init(
        baseUrl: String?,
        proxyRouteSource: ImpulseProxyRouteSource? = nil
    ) {
        self.keychain = ImpulseSystemKeychain()
        self.keychainAccessGroup = nil
        self.baseUrl = baseUrl
        self.routeSource = proxyRouteSource
    }


    init(
        keychain: any ImpulseKeychain,
        keychainAccessGroup: String?,
        baseUrl: String?,
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
        guard ImpulseNetworkEngineFactory.isConfigured(baseUrl: self.baseUrl) else {
            Logger.shared.log("ImpulseNetwork", "The RPC base URL is not configured, so the engine never connects")
            return ImpulseUnconfiguredNetworkEngine(context: context)
        }

        Logger.shared.log("ImpulseNetwork", "The engine is created (app extension: \(isAppExtension))")
        ImpulseDiagnostics.setSink({ (message: String) -> Void in
            Logger.shared.log("ImpulseNetwork", message)
        })

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
#if os(iOS)
        let clientName: String = "impulsem-ios"
#else
        let clientName: String = ImpulsePoolCarrier.clientName
#endif
        return ImpulseNetworkCompositionInputs(
            endpoints: try ImpulseEndpoints(baseUrl: self.baseUrl ?? ""),
            mapping: try ImpulseMapping.loadBundled(),
            keychain: self.keychain,
            keychainAccessGroup: self.resolvedAccessGroup(),
            identityClock: ImpulseSystemClock(),
            identityScheduler: ImpulseTaskScheduler(),
            declaration: ImpulseNetworkEngineFactory.makeDeclaration(environment: context.apiEnvironment),
            updateBridge: ImpulseUpdateBridge(context: context),
            routeSource: self.routeSource,
            clientName: clientName
        )
    }


    /// The declaration of this application and device, read from the api environment of the context: the api id, the device,
    /// the system and application versions and the language pack. The languages come from the current locale.
    static func makeDeclaration(environment: MTApiEnvironment) -> ImpulseDeclaration {
        let language: String = Locale.current.languageCode ?? "en"
        return ImpulseDeclaration(
            apiId: environment.apiId,
            deviceModel: environment.deviceModel ?? "",
            systemVersion: environment.systemVersion ?? "",
            appVersion: environment.appVersion ?? "",
            systemLangCode: language,
            langPack: environment.langPack ?? "",
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


    /// Whether the base URL names an RPC host the endpoints accept. A nil, empty or invalid URL is not configured.
    static func isConfigured(baseUrl: String?) -> Bool {
        guard let baseUrl: String = baseUrl, !baseUrl.isEmpty else {
            return false
        }

        return (try? ImpulseEndpoints(baseUrl: baseUrl)) != nil
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
