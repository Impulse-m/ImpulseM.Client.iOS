import CryptoKit
import Foundation


/// The diagnostic log of the transport. The owner sets the receiver once; until then nothing is logged. A message names a
/// method, a user or a state, and never carries a token value.
public enum ImpulseDiagnostics {
    private static let lock: NSLock = NSLock()
    private static var sink: (@Sendable (String) -> Void)? = nil


    /// Sets the receiver of the messages, or removes it when `newSink` is nil.
    public static func setSink(_ newSink: (@Sendable (String) -> Void)?) {
        ImpulseDiagnostics.lock.lock()
        ImpulseDiagnostics.sink = newSink
        ImpulseDiagnostics.lock.unlock()
    }


    /// Hands a message to the receiver, when one is set.
    public static func log(_ message: String) {
        ImpulseDiagnostics.lock.lock()
        let current: (@Sendable (String) -> Void)? = ImpulseDiagnostics.sink
        ImpulseDiagnostics.lock.unlock()

        current?(message)
    }


    /// A short tag of a connection identity that does not reveal it: the first four bytes of the SHA-256 of `sub` in hex,
    /// then `orig_iat`. Nil when the token is not a readable JWT with a subject.
    public static func identityTag(token: String?) -> String? {
        guard let text: String = token, let claims: ImpulseIdentityClaims = ImpulseIdentityClaims.parse(token: text) else {
            return nil
        }

        let digest: SHA256.Digest = SHA256.hash(data: Data(claims.sub.utf8))
        let subjectTag: String = digest.prefix(4).map { (byte: UInt8) -> String in
            return String(format: "%02x", byte)
        }.joined()

        let origIat: String
        if let seconds: Double = claims.origIat {
            origIat = String(Int64(seconds))
        } else {
            origIat = "none"
        }
        return subjectTag + " orig_iat " + origIat
    }
}
