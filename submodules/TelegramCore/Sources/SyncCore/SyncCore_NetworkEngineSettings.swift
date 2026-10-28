import Postbox

public struct NetworkEngineSettings: Codable, Equatable {
    public var engine: NetworkEngineKind
    
    public static var defaultSettings: NetworkEngineSettings {
        return NetworkEngineSettings(engine: .impulse)
    }
    
    public init(engine: NetworkEngineKind) {
        self.engine = engine
    }
    
    /// `.impulse` is the only selectable engine, so a stored value of an older engine (`rust`,
    /// `mtProtoKit`), a missing value and an unknown value all decode as `.impulse`.
    public init(from decoder: Decoder) throws {
        self.engine = NetworkEngineSettings.defaultSettings.engine
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        
        try container.encode(self.engine.rawValue, forKey: "engine_v2")
    }
}
