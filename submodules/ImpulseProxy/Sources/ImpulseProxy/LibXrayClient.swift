import Foundation
import LibXray


public enum LibXrayError: Error, Equatable {
    case malformedResponse(
        method: String
    )
    case responseTooLarge(
        method: String
    )
    case methodFailed(
        method: String,
        message: String
    )
}


/// Raw JSON Invoke transport of libXray. Implementations must be synchronous.
public protocol LibXrayBridge: Sendable {
    func invoke(
        requestJSON: String
    ) -> String?
}


/// Calls the desktop C ABI `CGoInvoke` and frees the returned buffer with `CGoFree`.
public final class LibXrayCGoBridge: LibXrayBridge, Sendable {
    public init() {
    }


    public func invoke(
        requestJSON: String
    ) -> String? {
        return requestJSON.withCString { (requestPointer: UnsafePointer<CChar>) -> String? in
            guard let responsePointer = CGoInvoke(UnsafeMutablePointer(mutating: requestPointer)) else {
                return nil
            }
            defer {
                CGoFree(responsePointer)
            }
            return String(cString: responsePointer)
        }
    }
}


/// Typed wrapper over the libXray JSON Invoke API (apiVersion 3).
/// Every call runs on one process-wide serial worker, because one Go runtime is allowed per process.
public final class LibXrayClient: Sendable {
    public static let apiVersion: Int = 3
    public static let maxResponseBytes: Int = 16 * 1024 * 1024

    private static let sharedWorker: DispatchQueue = DispatchQueue(label: "net.impulsem.proxy.libxray.worker")

    private let bridge: LibXrayBridge

    public init(
        bridge: LibXrayBridge
    ) {
        self.bridge = bridge
    }


    /// Converts share links (one `vless://` per line) into Xray outbounds. Each outbound is returned as compact JSON text.
    public func convertShareLinks(
        text: String
    ) throws -> [String] {
        let method: String = "convertShareLinksToXrayJson"
        let payload: [String: Any] = ["text": text]
        let data: Any? = try call(
            method: method,
            payload: payload
        )
        let object: [String: Any] = try LibXrayClient.objectOf(
            method: method,
            value: data
        )
        let outbounds: [Any] = try LibXrayClient.arrayOf(
            method: method,
            object: object,
            key: "outbounds"
        )
        return try outbounds.map { (outbound: Any) throws -> String in
            return try LibXrayClient.jsonText(
                method: method,
                value: outbound
            )
        }
    }


    /// Sends one envelope `{"apiVersion":3,"method":...,"payload":...}` and returns the response `data`.
    func call(
        method: String,
        payload: [String: Any]?
    ) throws -> Any? {
        var request: [String: Any] = [
            "apiVersion": LibXrayClient.apiVersion,
            "method": method,
        ]
        if let payload: [String: Any] = payload {
            request["payload"] = payload
        }
        let requestJSON: String = try LibXrayClient.jsonText(
            method: method,
            value: request
        )
        let bridge: LibXrayBridge = self.bridge
        let responseJSON: String? = LibXrayClient.sharedWorker.sync { () -> String? in
            return bridge.invoke(requestJSON: requestJSON)
        }
        return try LibXrayClient.decodeResponse(
            method: method,
            responseJSON: responseJSON
        )
    }


    static func decodeResponse(
        method: String,
        responseJSON: String?
    ) throws -> Any? {
        guard let text: String = responseJSON else {
            throw LibXrayError.malformedResponse(method: method)
        }
        guard text.utf8.count <= LibXrayClient.maxResponseBytes else {
            throw LibXrayError.responseTooLarge(method: method)
        }
        guard let responseData: Data = text.data(using: .utf8) else {
            throw LibXrayError.malformedResponse(method: method)
        }
        guard let parsed: Any = try? JSONSerialization.jsonObject(with: responseData, options: [.fragmentsAllowed]) else {
            throw LibXrayError.malformedResponse(method: method)
        }
        guard let response: [String: Any] = parsed as? [String: Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        guard let success: Bool = boolValue(response["success"]) else {
            throw LibXrayError.malformedResponse(method: method)
        }
        if !success {
            let message: String = (response["error"] as? String) ?? "unknown error"
            throw LibXrayError.methodFailed(
                method: method,
                message: message
            )
        }
        return response["data"]
    }


    private static func jsonText(
        method: String,
        value: Any
    ) throws -> String {
        guard let object: [String: Any] = value as? [String: Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        let data: Data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text: String = String(data: data, encoding: .utf8) else {
            throw LibXrayError.malformedResponse(method: method)
        }
        return text
    }


    private static func objectOf(
        method: String,
        value: Any?
    ) throws -> [String: Any] {
        guard let object: [String: Any] = value as? [String: Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        return object
    }


    private static func arrayOf(
        method: String,
        object: [String: Any],
        key: String
    ) throws -> [Any] {
        guard let array: [Any] = object[key] as? [Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        return array
    }


    private static func boolValue(
        _ value: Any?
    ) -> Bool? {
        guard let number: NSNumber = value as? NSNumber else {
            return nil
        }
        guard CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}
