import Foundation


/// A refresh reply that the carrier delivered but that is not a readable `RefreshSessionResponse`.
public enum ImpulseRefreshTransportError: Error, Equatable, Sendable {
    case undecodableReply
}


/// Sends `refreshSession` over the update socket or the token-less pool fleet and maps the reply to the refresh reply.
/// A server reply, including an RPC error, is returned as `.failure`; a call that got no server answer is thrown as
/// `ImpulseTokenError.carrierFailure`, so the session is kept.
public struct ImpulseCarrierRefreshTransport: ImpulseRefreshTransport {
    private static let refreshMethod: String = "refreshSession"

    private let updateSocket: any ImpulseRequestCarrier
    private let poolFleet: any ImpulseRequestCarrier


    /// Creates the transport over the carrier of the update socket and the carrier of the pool fleet.
    public init(
        updateSocket: any ImpulseRequestCarrier,
        poolFleet: any ImpulseRequestCarrier
    ) {
        self.updateSocket = updateSocket
        self.poolFleet = poolFleet
    }


    public func refreshSession(
        refreshToken: String,
        carrier: ImpulseRefreshCarrier,
        timeoutSeconds: TimeInterval
    ) async throws -> ImpulseRefreshReply {
        let target: any ImpulseRequestCarrier
        switch carrier {
        case .updateSocket:
            target = self.updateSocket

        case .poolFleet:
            target = self.poolFleet
        }

        let request: [UInt8] = ImpulseRefreshCodec.encodeRequest(refreshToken: refreshToken)
        let settled: Result<[UInt8], ImpulseCarrierFailure> = await target.send(
            method: ImpulseCarrierRefreshTransport.refreshMethod,
            data: request,
            timeoutSeconds: timeoutSeconds
        )

        switch settled {
        case .success(let reply):
            let authorization: ImpulseRefreshAuthorization = try ImpulseRefreshCodec.decodeAuthorization(reply: reply)
            return .authorization(authorization)

        case .failure(let failure):
            // The pool and the update socket share the update fleet's mapping. Only a server reply maps to an RPC error.
            if ImpulseErrors.rpcError(from: failure, fleet: .update) == nil {
                throw ImpulseTokenError.carrierFailure(failure)
            }
            return .failure(failure)
        }
    }
}


/// The hand-encoded messages of `refreshSession`, matching `ImpulseRpcPaths.encodeRefreshSession` and
/// `decodeRefreshSession` on Android.
internal enum ImpulseRefreshCodec {
    private static let refreshTokenField: Int = 1
    private static let userIdField: Int = 1
    private static let sessionTokenField: Int = 2
    private static let refreshTokenReplyField: Int = 3
    private static let graceField: Int = 4
    private static let varintWireType: Int = 0
    private static let bytesWireType: Int = 2


    /// `RefreshSessionRequest { string refresh_token = 1; }`. The field is always written, as proto3 writes a bytes field.
    internal static func encodeRequest(refreshToken: String) -> [UInt8] {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writeBytesField(
            field: ImpulseRefreshCodec.refreshTokenField,
            value: Array(refreshToken.utf8)
        )
        return writer.toByteArray()
    }


    /// `impulse.auth.RefreshSessionResponse { user_id = 1; session_token = 2; refresh_token = 3; grace = 4; }`. Absent
    /// fields read as an empty string or zero; other fields are skipped. The session checks belong to `ImpulseTokens`.
    internal static func decodeAuthorization(reply: [UInt8]) throws -> ImpulseRefreshAuthorization {
        var userId: Int64 = 0
        var sessionToken: String = ""
        var refreshToken: String = ""
        var grace: Int = 0

        do {
            var reader: ImpulseProtoReader = try ImpulseProtoReader(data: reply, offset: 0, length: reply.count)
            while try reader.next() {
                let field: Int = reader.field
                let wireType: Int = reader.wireType
                if field == ImpulseRefreshCodec.userIdField && wireType == ImpulseRefreshCodec.varintWireType {
                    userId = try reader.readInt64()
                } else if field == ImpulseRefreshCodec.sessionTokenField && wireType == ImpulseRefreshCodec.bytesWireType {
                    let bytes: [UInt8] = try reader.readBytes()
                    sessionToken = String(decoding: bytes, as: UTF8.self)
                } else if field == ImpulseRefreshCodec.refreshTokenReplyField && wireType == ImpulseRefreshCodec.bytesWireType {
                    let bytes: [UInt8] = try reader.readBytes()
                    refreshToken = String(decoding: bytes, as: UTF8.self)
                } else if field == ImpulseRefreshCodec.graceField && wireType == ImpulseRefreshCodec.varintWireType {
                    let value: Int64 = try reader.readInt64()
                    grace = Int(truncatingIfNeeded: value)
                }
            }
        } catch {
            throw ImpulseRefreshTransportError.undecodableReply
        }

        return ImpulseRefreshAuthorization(
            userId: userId,
            sessionToken: sessionToken,
            refreshToken: refreshToken,
            grace: grace
        )
    }
}
