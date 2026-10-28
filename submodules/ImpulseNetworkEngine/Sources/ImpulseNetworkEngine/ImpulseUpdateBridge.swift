import Foundation
import MtProtoKit
import TelegramCore
import ImpulseTransport


/// Receives the non-RPC messages of an ImpulseM session and hands them to TelegramCore's update sinks, in receive order.
/// A `updateDcOptions` is applied to the datacenter addresses of the context and is not handed on: it is configuration
/// of the connection, not a message of the account. Every other message is parsed by the context's serialization, the way
/// the other engines parse theirs.
final class ImpulseUpdateBridge: ImpulseUpdateSink {
    private let parse: (Data) -> Any?
    private let applyDcOptions: ([ImpulseDcUpdateOption]) -> Void
    private let lock: NSLock = NSLock()
    private var sinks: [NetworkEngineUpdateSink] = []


    init(
        parse: @escaping (Data) -> Any?,
        applyDcOptions: @escaping ([ImpulseDcUpdateOption]) -> Void
    ) {
        self.parse = parse
        self.applyDcOptions = applyDcOptions
    }


    /// The bridge of a context: messages are parsed by its serialization, and DC options are applied to its addresses.
    /// The bridge holds the context weakly; once the context is gone, messages are dropped.
    convenience init(context: MTContext) {
        self.init(
            parse: { [weak context] (data: Data) -> Any? in
                guard let context: MTContext = context else {
                    return nil
                }
                return context.serialization.parseMessage(data)
            },
            applyDcOptions: { [weak context] (options: [ImpulseDcUpdateOption]) -> Void in
                guard let context: MTContext = context else {
                    return
                }
                ImpulseDcOptionsApplier.apply(options: options, to: context)
            }
        )
    }


    /// Adds a TelegramCore update sink. The bridge keeps it for as long as the bridge lives.
    func addSink(_ sink: NetworkEngineUpdateSink) {
        self.lock.lock()
        self.sinks.append(sink)
        self.lock.unlock()
    }


    func networkSessionDidReset() {
        for sink: NetworkEngineUpdateSink in self.currentSinks() {
            sink.networkSessionDidReset()
        }
    }


    func networkSessionDidReceive(tl: [UInt8]) {
        if let options: [ImpulseDcUpdateOption] = ImpulseDcOptionsUpdate.dcOptions(tl: tl) {
            self.applyDcOptions(options)
            return
        }

        guard let message: Any = self.parse(Data(tl)) else {
            return
        }
        for sink: NetworkEngineUpdateSink in self.currentSinks() {
            sink.networkSessionDidReceive(message: message)
        }
    }


    private func currentSinks() -> [NetworkEngineUpdateSink] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sinks
    }
}
