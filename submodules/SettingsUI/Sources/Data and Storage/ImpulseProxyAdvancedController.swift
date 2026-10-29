import Foundation
import TelegramCore


/// Rules of the advanced proxy settings that do not depend on the page layout: the contract defaults and the
/// rule that decides whether a change restarts the Xray core. The values are the persisted
/// `ImpulseProxyState.Advanced` of the shared model.
public enum ImpulseProxyAdvancedRules {
    /// The advanced settings with every value set to its contract default, written out in full.
    public static func contractDefaults() -> ImpulseProxyState.Advanced {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fragmentMode = "off"
        advanced.fragmentPackets = "tlshello"
        advanced.fragmentLength = "100-200"
        advanced.fragmentInterval = "10-20"
        advanced.fragmentFromLink = true
        advanced.fingerprint = ""
        advanced.muxEnabled = false
        advanced.muxConcurrency = 8
        advanced.keepAliveIdle = 0
        advanced.keepAliveInterval = 0
        advanced.tcpFastOpen = false
        advanced.tcpMaxSeg = 0
        advanced.dnsMode = "system"
        advanced.dnsCustom = ""
        advanced.pingMode = "batch"
        advanced.pingPauseMillis = 0
        advanced.pingTimeoutSeconds = 5
        advanced.pingUrl = "https://www.gstatic.com/generate_204"
        advanced.pingSkipWhileConnected = true
        return advanced
    }


    /// True when a field that affects the core differs. Ping-only settings never restart the core.
    public static func restartRequired(
        previous: ImpulseProxyState.Advanced,
        next: ImpulseProxyState.Advanced
    ) -> Bool {
        var comparable: ImpulseProxyState.Advanced = next
        comparable.pingMode = previous.pingMode
        comparable.pingPauseMillis = previous.pingPauseMillis
        comparable.pingTimeoutSeconds = previous.pingTimeoutSeconds
        comparable.pingUrl = previous.pingUrl
        comparable.pingSkipWhileConnected = previous.pingSkipWhileConnected
        return previous != comparable
    }
}
