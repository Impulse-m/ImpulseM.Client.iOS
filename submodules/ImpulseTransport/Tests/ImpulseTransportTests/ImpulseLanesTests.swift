import XCTest
@testable import ImpulseTransport

final class ImpulseLanesTests: XCTestCase {
    func testNewestChannelsComeFirstAfterOpenedChannel() {
        let lanes: ImpulseLanes = ImpulseLanes()
        let candidates: [ImpulseLaneCandidate] = [
            ImpulseLaneCandidate(channelId: 10, lastMessageDate: 100),
            ImpulseLaneCandidate(channelId: 20, lastMessageDate: 300),
            ImpulseLaneCandidate(channelId: 30, lastMessageDate: 200),
        ]

        XCTAssertEqual(lanes.select(candidates: candidates, openedChannelId: 30), [30, 20, 10])
    }


    func testWithoutOpenedChannelOrderIsByRecency() {
        let lanes: ImpulseLanes = ImpulseLanes()
        let candidates: [ImpulseLaneCandidate] = [
            ImpulseLaneCandidate(channelId: 10, lastMessageDate: 100),
            ImpulseLaneCandidate(channelId: 20, lastMessageDate: 300),
        ]

        XCTAssertEqual(lanes.select(candidates: candidates, openedChannelId: 0), [20, 10])
    }


    func testNonPositiveChannelIdsAreIgnored() {
        let lanes: ImpulseLanes = ImpulseLanes()
        let candidates: [ImpulseLaneCandidate] = [
            ImpulseLaneCandidate(channelId: 0, lastMessageDate: 999),
            ImpulseLaneCandidate(channelId: -5, lastMessageDate: 998),
            ImpulseLaneCandidate(channelId: 7, lastMessageDate: 1),
        ]

        XCTAssertEqual(lanes.select(candidates: candidates, openedChannelId: -1), [7])
    }


    func testOpenedChannelIsNotRepeatedFromCandidates() {
        let lanes: ImpulseLanes = ImpulseLanes()
        let candidates: [ImpulseLaneCandidate] = [
            ImpulseLaneCandidate(channelId: 5, lastMessageDate: 500),
            ImpulseLaneCandidate(channelId: 6, lastMessageDate: 400),
        ]

        XCTAssertEqual(lanes.select(candidates: candidates, openedChannelId: 5), [5, 6])
    }


    func testDuplicateCandidatesKeepTheirFirstPosition() {
        let lanes: ImpulseLanes = ImpulseLanes()
        let candidates: [ImpulseLaneCandidate] = [
            ImpulseLaneCandidate(channelId: 8, lastMessageDate: 100),
            ImpulseLaneCandidate(channelId: 9, lastMessageDate: 300),
            ImpulseLaneCandidate(channelId: 8, lastMessageDate: 500),
        ]

        XCTAssertEqual(lanes.select(candidates: candidates, openedChannelId: 0), [8, 9])
    }


    func testEqualDatesKeepInputOrder() {
        let lanes: ImpulseLanes = ImpulseLanes()
        let candidates: [ImpulseLaneCandidate] = [
            ImpulseLaneCandidate(channelId: 3, lastMessageDate: 50),
            ImpulseLaneCandidate(channelId: 1, lastMessageDate: 50),
            ImpulseLaneCandidate(channelId: 2, lastMessageDate: 50),
        ]

        XCTAssertEqual(lanes.select(candidates: candidates, openedChannelId: 0), [3, 1, 2])
    }


    func testCapIncludesOpenedChannel() {
        let lanes: ImpulseLanes = ImpulseLanes(cap: 3)
        let candidates: [ImpulseLaneCandidate] = [
            ImpulseLaneCandidate(channelId: 1, lastMessageDate: 10),
            ImpulseLaneCandidate(channelId: 2, lastMessageDate: 20),
            ImpulseLaneCandidate(channelId: 3, lastMessageDate: 30),
            ImpulseLaneCandidate(channelId: 4, lastMessageDate: 40),
        ]

        XCTAssertEqual(lanes.select(candidates: candidates, openedChannelId: 1), [1, 4, 3])
    }


    func testDefaultCapIsThirtyTwo() {
        let lanes: ImpulseLanes = ImpulseLanes()
        var candidates: [ImpulseLaneCandidate] = []
        for index in 1...40 {
            candidates.append(ImpulseLaneCandidate(channelId: Int64(index), lastMessageDate: Int32(index)))
        }

        let selected: [Int64] = lanes.select(candidates: candidates, openedChannelId: 0)
        XCTAssertEqual(selected.count, 32)
        XCTAssertEqual(selected.first, 40)
        XCTAssertEqual(selected.last, 9)
    }


    func testNonPositiveCapReturnsNothing() {
        let lanes: ImpulseLanes = ImpulseLanes(cap: 0)
        let candidates: [ImpulseLaneCandidate] = [
            ImpulseLaneCandidate(channelId: 1, lastMessageDate: 10),
        ]

        XCTAssertEqual(lanes.select(candidates: candidates, openedChannelId: 2), [])
    }


    func testEmptyCandidatesReturnOnlyOpenedChannel() {
        let lanes: ImpulseLanes = ImpulseLanes()

        XCTAssertEqual(lanes.select(candidates: [], openedChannelId: 4), [4])
    }


    func testDebounceIsAParameterWithDefaultValue() {
        let defaultLanes: ImpulseLanes = ImpulseLanes()
        let customLanes: ImpulseLanes = ImpulseLanes(debounceMilliseconds: 150)

        XCTAssertEqual(defaultLanes.debounceMilliseconds, 500)
        XCTAssertEqual(customLanes.debounceMilliseconds, 150)
    }
}
