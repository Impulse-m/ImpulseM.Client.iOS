import Foundation
import SwiftCentrifuge
import ImpulseTransport


/// Why a connection credential or an identity renewal could not be supplied.
enum ImpulseNetworkCompositionError: Error {
    /// The account parts are not bound yet, so no credential can be read.
    case notBound
    /// No session is stored, so the media fleet has no token to present.
    case noSession
}


/// The account parts the socket clients and the pool call back into.
struct ImpulseAccountParts {
    let tokens: ImpulseTokens
    let identity: ImpulseIdentityManager
    let credentials: ImpulseConnectionCredentialCache
    let declarer: ImpulseConnectionDeclarer
}


/// The callbacks that the socket clients and the pool are created with. Those clients are built before the tokens and the
/// identity that answer them, so the link is bound once every part exists. Until then the callbacks fail with `notBound`.
final class ImpulseAccountLink {
    private let lock: NSLock = NSLock()
    private var parts: ImpulseAccountParts?


    init() {
    }


    /// Binds the parts the callbacks answer with.
    func bind(parts: ImpulseAccountParts) {
        self.lock.lock()
        self.parts = parts
        self.lock.unlock()
    }


    /// The connection token of the update socket and the pool: the access token of the session, refreshed when it needs it,
    /// else the connection identity, minted when none is stored. The credential cache records what was handed out, so the
    /// declaration is keyed by the credential the socket presents.
    func connectionToken(completion: @escaping (Result<String, Error>) -> Void) {
        guard let current: ImpulseAccountParts = self.currentParts() else {
            completion(.failure(ImpulseNetworkCompositionError.notBound))
            return
        }
        Task {
            do {
                if let accessToken: String = try await current.tokens.connectionToken() {
                    current.credentials.setSessionAccessToken(accessToken)
                    await current.declarer.credentialChanged()
                    completion(.success(accessToken))
                    return
                }
                let identityToken: String = try await current.identity.obtain()
                current.credentials.setIdentityToken(identityToken)
                await current.declarer.credentialChanged()
                completion(.success(identityToken))
            } catch {
                completion(.failure(error))
            }
        }
    }


    /// The access token of the session for the media fleet. Without a session there is no token, and the fleet fails its calls.
    func mediaToken(completion: @escaping (Result<String, Error>) -> Void) {
        guard let current: ImpulseAccountParts = self.currentParts() else {
            completion(.failure(ImpulseNetworkCompositionError.notBound))
            return
        }
        Task {
            do {
                guard let accessToken: String = try await current.tokens.connectionToken() else {
                    completion(.failure(ImpulseNetworkCompositionError.noSession))
                    return
                }
                completion(.success(accessToken))
            } catch {
                completion(.failure(error))
            }
        }
    }


    /// Obtains the identity again after the pool's session ended, so the pool connects with a fresh one.
    func renewIdentity(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let current: ImpulseAccountParts = self.currentParts() else {
            completion(.failure(ImpulseNetworkCompositionError.notBound))
            return
        }
        Task {
            do {
                _ = try await current.identity.obtain()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }


    private func currentParts() -> ImpulseAccountParts? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.parts
    }
}
