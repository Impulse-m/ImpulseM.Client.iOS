import Foundation


/// Sends `connectionIdentity` through a request carrier that serves the token-less pool, such as `ImpulsePoolRequestCarrier`.
///
/// The request and the reply are hand-encoded messages of the identity service. `ConnectionIdentityRequest` carries the
/// identity token as field 1 and the api id as field 2. `ConnectionIdentityResponse` carries the identity token as field
/// 1. Unset and empty fields are not written, as proto3 does. A reply without a token is a null identity, returned as "".
public struct ImpulsePoolIdentityCarrier: ImpulseIdentityCarrier {
    /// The method the pool serves for the connection identity.
    public static let methodName: String = "connectionIdentity"

    private static let identityTokenField: Int = 1
    private static let apiIdField: Int = 2
    private static let replyTokenField: Int = 1
    private static let lengthDelimitedWireType: Int = 2

    private let carrier: any ImpulseRequestCarrier


    /// Creates the carrier over a request carrier that serves the pool.
    public init(carrier: any ImpulseRequestCarrier) {
        self.carrier = carrier
    }


    /// Sends one `connectionIdentity` call. An empty token mints an identity; a non-empty one renews that identity.
    /// A failed call throws its carrier failure, unchanged.
    public func connectionIdentity(
        identityToken: String,
        apiId: Int32,
        timeoutSeconds: Double
    ) async throws -> String {
        let request: [UInt8] = ImpulsePoolIdentityCarrier.encodeRequest(
            identityToken: identityToken,
            apiId: apiId
        )
        let result: Result<[UInt8], ImpulseCarrierFailure> = await self.carrier.send(
            method: ImpulsePoolIdentityCarrier.methodName,
            data: request,
            timeoutSeconds: timeoutSeconds
        )
        switch result {
        case .success(let reply):
            return try ImpulsePoolIdentityCarrier.decodeReply(reply)

        case .failure(let failure):
            throw failure
        }
    }


    /// `ConnectionIdentityRequest { string identity_token = 1; int32 api_id = 2; }`.
    internal static func encodeRequest(
        identityToken: String,
        apiId: Int32
    ) -> [UInt8] {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        if !identityToken.isEmpty {
            writer.writeBytesField(
                field: ImpulsePoolIdentityCarrier.identityTokenField,
                value: Array(identityToken.utf8)
            )
        }
        if apiId != 0 {
            writer.writeInt32Field(
                field: ImpulsePoolIdentityCarrier.apiIdField,
                value: apiId
            )
        }
        return writer.toByteArray()
    }


    /// `ConnectionIdentityResponse { string identity_token = 1; }`. The last token field wins, and the result is "" when
    /// no token is present. Fields of other numbers and wire types are skipped.
    internal static func decodeReply(_ reply: [UInt8]) throws -> String {
        var token: String = ""
        var reader: ImpulseProtoReader = try ImpulseProtoReader(
            data: reply,
            offset: 0,
            length: reply.count
        )
        while try reader.next() {
            let isTokenField: Bool = reader.field == ImpulsePoolIdentityCarrier.replyTokenField
            let isLengthDelimited: Bool = reader.wireType == ImpulsePoolIdentityCarrier.lengthDelimitedWireType
            if isTokenField && isLengthDelimited {
                let bytes: [UInt8] = try reader.readBytes()
                token = String(decoding: bytes, as: UTF8.self)
            }
        }
        return token
    }
}
