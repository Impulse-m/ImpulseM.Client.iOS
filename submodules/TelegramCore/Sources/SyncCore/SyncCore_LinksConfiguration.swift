import Foundation
import Postbox

public struct LinksConfiguration: Equatable, Codable {
    private enum CodingKeys: String, CodingKey {
        case autologinToken
        case meUrlPrefix
    }

    public let autologinToken: String?
    /// `me_url_prefix` from `help.getConfig`, as the server sent it. Nil until the first config arrives.
    public let meUrlPrefix: String?

    public static var defaultValue: LinksConfiguration {
        return LinksConfiguration(autologinToken: nil, meUrlPrefix: nil)
    }

    public init(autologinToken: String?, meUrlPrefix: String? = nil) {
        self.autologinToken = autologinToken
        self.meUrlPrefix = meUrlPrefix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.autologinToken = try container.decodeIfPresent(String.self, forKey: .autologinToken)
        self.meUrlPrefix = try container.decodeIfPresent(String.self, forKey: .meUrlPrefix)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(self.autologinToken, forKey: .autologinToken)
        try container.encodeIfPresent(self.meUrlPrefix, forKey: .meUrlPrefix)
    }
}

public func currentLinksConfiguration(transaction: Transaction) -> LinksConfiguration {
    if let entry = transaction.getPreferencesEntry(key: PreferencesKeys.linksConfiguration)?.get(LinksConfiguration.self) {
        return entry
    } else {
        return LinksConfiguration.defaultValue
    }
}

func updateLinksConfiguration(transaction: Transaction, configuration: LinksConfiguration) {
    if currentLinksConfiguration(transaction: transaction) != configuration {
        transaction.setPreferencesEntry(key: PreferencesKeys.linksConfiguration, value: PreferencesEntry(configuration))
    }
}
