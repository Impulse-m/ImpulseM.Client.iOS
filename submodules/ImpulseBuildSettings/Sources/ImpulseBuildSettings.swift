import Foundation
import BuildConfig

/// The one place the app reads its owner-service addresses: the IMPULSEM_* build variables
/// (impulsem-configuration.json, passed through BuildConfig). Every empty value reads as nil,
/// and every consumer must handle nil by hiding the feature instead of building a link.
public enum ImpulseBuildSettings {
    private static let buildConfig: BuildConfig = BuildConfig(baseAppBundleId: "")

    /// Transport base URL (IMPULSEM_RPC_URL) without a trailing slash, nil when not configured.
    public static var rpcUrl: String? {
        return normalizedBaseUrl(self.buildConfig.impulsemRpcUrl)
    }

    /// Website base URL (IMPULSEM_SITE_URL) without a trailing slash, nil when not configured.
    public static var siteUrl: String? {
        return normalizedBaseUrl(self.buildConfig.impulsemSiteUrl)
    }

    /// Web client URL (IMPULSEM_WEB_URL) without a trailing slash, nil when not configured.
    public static var webUrl: String? {
        return normalizedBaseUrl(self.buildConfig.impulsemWebUrl)
    }

    /// Share and deep-link host (IMPULSEM_LINK_HOST), lowercased and without scheme or slashes, nil when not configured.
    public static var linkHost: String? {
        var value: String = self.buildConfig.impulsemLinkHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("https://") {
            value.removeFirst("https://".count)
        } else if value.hasPrefix("http://") {
            value.removeFirst("http://".count)
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    /// The hosts that name the owner's share links, empty when IMPULSEM_LINK_HOST is not configured.
    public static var linkHosts: [String] {
        if let linkHost = self.linkHost {
            return [linkHost]
        } else {
            return []
        }
    }

    /// The owner's own hosts, lowercased: the link host and the host of the website. Empty when neither is configured.
    public static var ownerHosts: [String] {
        var hosts: [String] = self.linkHosts
        if let siteUrl = self.siteUrl, let siteHost = URL(string: siteUrl)?.host?.lowercased(), !hosts.contains(siteHost) {
            hosts.append(siteHost)
        }
        return hosts
    }

    /// A website page: the site base URL followed by `path` (which starts with "/"), nil when IMPULSEM_SITE_URL is not configured.
    public static func siteLink(path: String) -> String? {
        guard let siteUrl = self.siteUrl else {
            return nil
        }
        return siteUrl + path
    }

    private static func normalizedBaseUrl(_ value: String) -> String? {
        var result: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result.isEmpty ? nil : result
    }
}
