import Foundation

public struct ImpulseLaneCandidate: Equatable, Sendable {
    public let channelId: Int64
    public let lastMessageDate: Int32

    public init(
        channelId: Int64,
        lastMessageDate: Int32
    ) {
        self.channelId = channelId
        self.lastMessageDate = lastMessageDate
    }
}


/// Chooses which channels get a realtime lane: the opened channel first, then the most recently active channels.
public struct ImpulseLanes: Equatable, Sendable {
    public static let defaultCap: Int = 32
    public static let defaultDebounceMilliseconds: Int = 500

    /// The most channel lanes one connection may hold.
    public let cap: Int

    /// Delay the caller applies between a dialog change and a recompute. The selection itself does not wait.
    public let debounceMilliseconds: Int


    public init(
        cap: Int = ImpulseLanes.defaultCap,
        debounceMilliseconds: Int = ImpulseLanes.defaultDebounceMilliseconds
    ) {
        self.cap = cap
        self.debounceMilliseconds = debounceMilliseconds
    }


    /// Returns channel ids in priority order: the opened channel, then newest first.
    /// Candidates with non-positive ids are ignored, duplicates keep their first position, and the result never exceeds `cap`.
    public func select(
        candidates: [ImpulseLaneCandidate],
        openedChannelId: Int64
    ) -> [Int64] {
        guard cap > 0 else {
            return []
        }

        var result: [Int64] = []
        var seen: Set<Int64> = []

        if openedChannelId > 0 {
            result.append(openedChannelId)
            seen.insert(openedChannelId)
        }

        var ranked: [ImpulseLaneRank] = []
        for index in candidates.indices {
            let candidate: ImpulseLaneCandidate = candidates[index]
            if candidate.channelId > 0 {
                ranked.append(ImpulseLaneRank(position: index, candidate: candidate))
            }
        }

        ranked.sort(by: { (left: ImpulseLaneRank, right: ImpulseLaneRank) -> Bool in
            if left.candidate.lastMessageDate != right.candidate.lastMessageDate {
                return left.candidate.lastMessageDate > right.candidate.lastMessageDate
            }

            return left.position < right.position
        })

        for rank in ranked {
            if result.count >= cap {
                break
            }

            let channelId: Int64 = rank.candidate.channelId
            if seen.contains(channelId) {
                continue
            }

            seen.insert(channelId)
            result.append(channelId)
        }

        return result
    }
}


private struct ImpulseLaneRank {
    let position: Int
    let candidate: ImpulseLaneCandidate
}
