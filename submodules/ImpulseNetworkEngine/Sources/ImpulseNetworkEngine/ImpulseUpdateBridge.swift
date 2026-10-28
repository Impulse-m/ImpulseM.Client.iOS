import Foundation
import MtProtoKit
import TelegramCore
import ImpulseTransport


/// Receives the non-RPC messages of an ImpulseM session and hands them to TelegramCore's update sinks, in receive order.
/// A `updateDcOptions` that arrives on the system config lane is applied to the datacenter addresses of the context and
/// is not handed on: it is configuration of the connection, not a message of the account. A DC options update on any other
/// lane is not configuration, so it is handed on like every other message. Every other message is parsed by the context's
/// serialization, the way the other engines parse theirs.
final class ImpulseUpdateBridge: ImpulseUpdateSink {
    private let parse: (Data) -> Any?
    private let knownDatacenterIds: () -> Set<Int32>
    private let applyDcOptions: ([ImpulseDcUpdateOption]) -> Void
    private let lock: NSLock = NSLock()
    private var sinks: [NetworkEngineUpdateSink] = []


    init(
        parse: @escaping (Data) -> Any?,
        knownDatacenterIds: @escaping () -> Set<Int32>,
        applyDcOptions: @escaping ([ImpulseDcUpdateOption]) -> Void
    ) {
        self.parse = parse
        self.knownDatacenterIds = knownDatacenterIds
        self.applyDcOptions = applyDcOptions
    }


    /// The bridge of a context: messages are parsed by its serialization, and DC options are applied to its addresses
    /// for the datacenters it knows. The bridge holds the context weakly; once the context is gone, messages are dropped.
    convenience init(context: MTContext) {
        self.init(
            parse: { [weak context] (data: Data) -> Any? in
                guard let context: MTContext = context else {
                    return nil
                }
                return context.serialization.parseMessage(data)
            },
            knownDatacenterIds: { [weak context] () -> Set<Int32> in
                guard let context: MTContext = context else {
                    return []
                }
                let values: [Any] = context.knownDatacenterIds()
                return Set(values.compactMap { (value: Any) -> Int32? in
                    return (value as? NSNumber)?.int32Value
                })
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


    func networkSessionDidReceive(
        tl: [UInt8],
        channel: String
    ) {
        if channel == ImpulseLaneRouter.systemConfigLane, let options: [ImpulseDcUpdateOption] = ImpulseDcOptionsUpdate.dcOptions(tl: tl) {
            let valid: [ImpulseDcUpdateOption] = self.validOptions(options)
            if !valid.isEmpty {
                self.applyDcOptions(valid)
            }
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


    /// The options that may be applied. Each option that is dropped is logged with the reason.
    private func validOptions(_ options: [ImpulseDcUpdateOption]) -> [ImpulseDcUpdateOption] {
        let known: Set<Int32> = self.knownDatacenterIds()
        var valid: [ImpulseDcUpdateOption] = []
        for option: ImpulseDcUpdateOption in options {
            if let reason: String = ImpulseUpdateBridge.rejectionReason(of: option, knownDatacenterIds: known) {
                Logger.shared.log("ImpulseNetwork", "Dropped DC option \(option.id): \(reason)")
                continue
            }
            valid.append(option)
        }
        return valid
    }


    /// Why an option must not be applied, or nil when it may be applied.
    private static func rejectionReason(
        of option: ImpulseDcUpdateOption,
        knownDatacenterIds: Set<Int32>
    ) -> String? {
        if !knownDatacenterIds.contains(option.id) {
            return "unknown datacenter"
        }
        if !ImpulseUpdateBridge.isIpAddress(option.ipAddress) {
            return "address is neither IPv4 nor IPv6"
        }
        if option.port < 1 || option.port > 65535 {
            return "port \(option.port) is out of range"
        }
        return nil
    }


    private static func isIpAddress(_ text: String) -> Bool {
        var ipv4: in_addr = in_addr()
        if inet_pton(AF_INET, text, &ipv4) == 1 {
            return true
        }
        var ipv6: in6_addr = in6_addr()
        return inet_pton(AF_INET6, text, &ipv6) == 1
    }
}
