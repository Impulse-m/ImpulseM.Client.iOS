/// What the client tells the server about its application, device and languages: the initConnection declaration.
///
/// Fields of the declaration: `api_id` = 1, `device_model` = 2, `system_version` = 3, `app_version` = 4,
/// `system_lang_code` = 5, `lang_pack` = 6, `lang_code` = 7. The `proxy` (8) and `params` (9) fields are never written.
/// Every string is cut to the server's limit on a grapheme boundary when the declaration is built, so the stored and
/// the compared values are the ones the server receives.
public struct ImpulseDeclaration: Equatable, Sendable {
    public static let macosLangPack: String = "macos"
    public static let initConnectionMethod: String = "initConnection"
    public static let deviceModelMaxLength: Int = 100
    public static let systemVersionMaxLength: Int = 50
    public static let appVersionMaxLength: Int = 50
    public static let systemLangCodeMaxLength: Int = 32
    public static let langPackMaxLength: Int = 50
    public static let langCodeMaxLength: Int = 64


    public let apiId: Int32
    public let deviceModel: String
    public let systemVersion: String
    public let appVersion: String
    public let systemLangCode: String
    public let langPack: String
    public let langCode: String


    public init(
        apiId: Int32,
        deviceModel: String,
        systemVersion: String,
        appVersion: String,
        systemLangCode: String,
        langPack: String,
        langCode: String
    ) {
        self.apiId = apiId
        self.deviceModel = ImpulseDeclaration.fit(deviceModel, maxLength: ImpulseDeclaration.deviceModelMaxLength)
        self.systemVersion = ImpulseDeclaration.fit(systemVersion, maxLength: ImpulseDeclaration.systemVersionMaxLength)
        self.appVersion = ImpulseDeclaration.fit(appVersion, maxLength: ImpulseDeclaration.appVersionMaxLength)
        self.systemLangCode = ImpulseDeclaration.fit(systemLangCode, maxLength: ImpulseDeclaration.systemLangCodeMaxLength)
        self.langPack = ImpulseDeclaration.fit(langPack, maxLength: ImpulseDeclaration.langPackMaxLength)
        self.langCode = ImpulseDeclaration.fit(langCode, maxLength: ImpulseDeclaration.langCodeMaxLength)
    }


    /// The same declaration with another current language, used on a language switch.
    public func withLangCode(_ value: String) -> ImpulseDeclaration {
        return ImpulseDeclaration(
            apiId: apiId,
            deviceModel: deviceModel,
            systemVersion: systemVersion,
            appVersion: appVersion,
            systemLangCode: systemLangCode,
            langPack: langPack,
            langCode: value
        )
    }


    /// The same declaration with another system language.
    public func withSystemLangCode(_ value: String) -> ImpulseDeclaration {
        return ImpulseDeclaration(
            apiId: apiId,
            deviceModel: deviceModel,
            systemVersion: systemVersion,
            appVersion: appVersion,
            systemLangCode: value,
            langPack: langPack,
            langCode: langCode
        )
    }


    /// The protobuf body of the initConnection request: `InitConnectionRequest { ConnectionDeclaration declaration = 1; }`.
    /// Empty strings and a zero `api_id` are omitted, as proto3 does.
    public func initConnectionRequest() -> [UInt8] {
        var inner: ImpulseProtoWriter = ImpulseProtoWriter()
        if apiId != 0 {
            inner.writeInt32Field(field: 1, value: apiId)
        }
        ImpulseDeclaration.writeString(&inner, field: 2, value: deviceModel)
        ImpulseDeclaration.writeString(&inner, field: 3, value: systemVersion)
        ImpulseDeclaration.writeString(&inner, field: 4, value: appVersion)
        ImpulseDeclaration.writeString(&inner, field: 5, value: systemLangCode)
        ImpulseDeclaration.writeString(&inner, field: 6, value: langPack)
        ImpulseDeclaration.writeString(&inner, field: 7, value: langCode)
        var outer: ImpulseProtoWriter = ImpulseProtoWriter()
        outer.writeBytesField(field: 1, value: inner.toByteArray())
        return outer.toByteArray()
    }


    private static func writeString(
        _ writer: inout ImpulseProtoWriter,
        field: Int,
        value: String
    ) {
        if !value.isEmpty {
            writer.writeBytesField(field: field, value: Array(value.utf8))
        }
    }


    /// Cuts the value to at most `maxLength` UTF-16 units, dropping whole grapheme clusters only.
    private static func fit(
        _ value: String,
        maxLength: Int
    ) -> String {
        if value.utf16.count <= maxLength {
            return value
        }
        var result: String = ""
        var length: Int = 0
        for character: Character in value {
            let units: Int = String(character).utf16.count
            if length + units > maxLength {
                break
            }
            result.append(character)
            length += units
        }
        return result
    }
}


/// The key the declarer compares: the credential the update socket presents and the declaration sent with it.
/// A declaration is sent once per key; a change of either part makes a new key that must be declared again.
public struct ImpulseDeclarationKey: Equatable, Sendable {
    public let credential: String
    public let declaration: ImpulseDeclaration


    public init(
        credential: String,
        declaration: ImpulseDeclaration
    ) {
        self.credential = credential
        self.declaration = declaration
    }
}
