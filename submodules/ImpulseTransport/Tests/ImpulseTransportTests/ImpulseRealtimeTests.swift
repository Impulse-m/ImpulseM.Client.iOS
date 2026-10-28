import XCTest
@testable import ImpulseTransport


/// Records the socket calls in order, and holds the listener weakly as the real socket does.
private final class ImpulseRealtimeSocketDouble: ImpulseRealtimeSocket {
    weak var listener: (any ImpulseRealtimeSocketListener)?
    private(set) var calls: [String] = []


    func connect() {
        calls.append("connect")
    }


    func disconnect() {
        calls.append("disconnect")
    }


    func setConnectionToken(_ token: String) {
        calls.append("token " + token)
    }


    func subscribe(
        channel: String,
        positioned: Bool,
        recoverable: Bool
    ) {
        calls.append("subscribe \(channel) \(positioned) \(recoverable)")
    }


    func unsubscribe(channel: String) {
        calls.append("unsubscribe " + channel)
    }
}


/// Collects what the realtime client hands to the application.
private final class ImpulseRealtimeRecorder {
    private(set) var differences: [ImpulseDifferenceRequest] = []
    private(set) var updates: [ImpulseRealtimeUpdates] = []


    func recordDifference(_ request: ImpulseDifferenceRequest) {
        differences.append(request)
    }


    func recordUpdates(_ value: ImpulseRealtimeUpdates) {
        updates.append(value)
    }
}


final class ImpulseRealtimeTests: XCTestCase {
    private struct Fixture {
        let mapping: ImpulseMapping
        let transcoder: ImpulseTranscoder
        let socket: ImpulseRealtimeSocketDouble
        let recorder: ImpulseRealtimeRecorder
        let realtime: ImpulseRealtime
    }


    private func makeFixture() throws -> Fixture {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let socket: ImpulseRealtimeSocketDouble = ImpulseRealtimeSocketDouble()
        let recorder: ImpulseRealtimeRecorder = ImpulseRealtimeRecorder()
        let realtime: ImpulseRealtime = ImpulseRealtime(
            mapping: mapping,
            socket: socket,
            differenceHandler: { (request: ImpulseDifferenceRequest) -> Void in
                recorder.recordDifference(request)
            },
            updateHandler: { (updates: ImpulseRealtimeUpdates) -> Void in
                recorder.recordUpdates(updates)
            }
        )
        return Fixture(
            mapping: mapping,
            transcoder: transcoder,
            socket: socket,
            recorder: recorder,
            realtime: realtime
        )
    }


    private func userPlan(_ userId: Int64) -> ImpulseSyncPlan {
        return ImpulseSyncPlan(
            dropUserLane: 0,
            stopLanes: false,
            disconnect: false,
            subscribeUserLane: userId,
            connect: false
        )
    }


    /// The TL bytes of a bare constructor id, with no fields.
    private func constructorOnlyTl(_ id: UInt32) -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: id))
        return writer.toByteArray()
    }


    /// The publication bytes of a TL Updates object: the protobuf body inside the envelope JSON.
    private func publicationData(
        tl: [UInt8],
        transcoder: ImpulseTranscoder
    ) throws -> Data {
        let proto: [UInt8] = try transcoder.tlObjectToProto(typeName: ImpulseRealtime.updatesTypeName, tl: tl)
        let envelope: ImpulseEnvelope = ImpulseEnvelope.ptsLess(type: 9, date: 1700000000, body: Data(proto))
        return try envelope.jsonData()
    }


    func testUserLaneSubscribesPositionedAndRecoverable() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.apply(plan: ImpulseSyncPlan(
            dropUserLane: 0,
            stopLanes: false,
            disconnect: false,
            subscribeUserLane: 5,
            connect: true
        ))

        XCTAssertEqual(fixture.socket.calls, ["subscribe user:5 true true", "connect"])
    }


    func testSignInPlanRunsDropStopDisconnectSubscribeConnectInOrder() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.apply(plan: ImpulseSyncPlan(
            dropUserLane: 3,
            stopLanes: true,
            disconnect: true,
            subscribeUserLane: 5,
            connect: true
        ))

        XCTAssertEqual(fixture.socket.calls, [
            "unsubscribe user:3",
            "disconnect",
            "subscribe user:5 true true",
            "connect",
        ])
    }


    func testRekeyDisconnectsSetsTokenAndConnects() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.rekey(token: "access")

        XCTAssertEqual(fixture.socket.calls, ["disconnect", "token access", "connect"])
    }


    func testChannelLanesFollowSelectionOnceUserLaneIsSet() throws {
        let fixture: Fixture = try makeFixture()
        fixture.realtime.apply(plan: userPlan(5))

        fixture.realtime.applyLanes(
            candidates: [
                ImpulseLaneCandidate(channelId: 10, lastMessageDate: 100),
                ImpulseLaneCandidate(channelId: 20, lastMessageDate: 300),
            ],
            openedChannelId: 9
        )

        XCTAssertEqual(fixture.socket.calls, [
            "subscribe user:5 true true",
            "subscribe channel:9 true true",
            "subscribe channel:20 true true",
            "subscribe channel:10 true true",
        ])
    }


    func testChannelLanesAreCappedAtThirtyTwo() throws {
        let fixture: Fixture = try makeFixture()
        fixture.realtime.apply(plan: userPlan(5))
        var candidates: [ImpulseLaneCandidate] = []
        for index: Int in 1...40 {
            candidates.append(ImpulseLaneCandidate(channelId: Int64(index), lastMessageDate: Int32(index)))
        }

        fixture.realtime.applyLanes(candidates: candidates, openedChannelId: 0)

        let channelSubscribes: [String] = fixture.socket.calls.filter { (call: String) -> Bool in
            return call.hasPrefix("subscribe channel:")
        }
        XCTAssertEqual(channelSubscribes.count, ImpulseLanes.defaultCap)
    }


    func testChannelLanesAreNotSubscribedWithoutUserLane() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.applyLanes(
            candidates: [ImpulseLaneCandidate(channelId: 10, lastMessageDate: 100)],
            openedChannelId: 9
        )

        XCTAssertEqual(fixture.socket.calls, [])
    }


    func testStopLanesUnsubscribesEveryChannelLane() throws {
        let fixture: Fixture = try makeFixture()
        fixture.realtime.apply(plan: userPlan(5))
        fixture.realtime.applyLanes(
            candidates: [
                ImpulseLaneCandidate(channelId: 11, lastMessageDate: 1),
                ImpulseLaneCandidate(channelId: 10, lastMessageDate: 1),
            ],
            openedChannelId: 0
        )

        fixture.realtime.apply(plan: ImpulseSyncPlan(
            dropUserLane: 0,
            stopLanes: true,
            disconnect: false,
            subscribeUserLane: 0,
            connect: false
        ))

        let tail: [String] = Array(fixture.socket.calls.suffix(2))
        XCTAssertEqual(tail, [
            "unsubscribe channel:10",
            "unsubscribe channel:11",
        ])
    }


    func testRecoveredUserLaneWithoutDropNeedsNoDifference() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handleSubscribed(channel: "user:5", recovered: true, wasRecovering: true)

        XCTAssertEqual(fixture.recorder.differences, [])
    }


    func testFreshUserLaneSubscribeRequestsAccountDifference() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handleSubscribed(channel: "user:5", recovered: false, wasRecovering: false)

        XCTAssertEqual(fixture.recorder.differences, [.account(.subscribeNotRecovered)])
    }


    func testForcedPositionDropRequestsAccountDifferenceEvenWhenRecovered() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handleUnsubscribed(channel: "user:5", code: 2502)
        fixture.realtime.handleSubscribed(channel: "user:5", recovered: true, wasRecovering: true)

        XCTAssertEqual(fixture.recorder.differences, [.account(.subscribePositionDropped)])
    }


    func testLostChannelPositionRequestsChannelDifference() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handleSubscribed(channel: "channel:9", recovered: false, wasRecovering: true)

        XCTAssertEqual(fixture.recorder.differences, [.channel(channelId: 9, reason: .subscribeNotRecovered)])
    }


    func testValidUpdatesArePassedAsTlToTheApplication() throws {
        let fixture: Fixture = try makeFixture()
        let constructor: ImpulseMappingConstructor = try XCTUnwrap(fixture.mapping.constructor(id: 1957577280))
        let tl: [UInt8] = try ImpulseTlSynth(mapping: fixture.mapping).constructorTl(constructor: constructor, allFlags: false)
        let data: Data = try publicationData(tl: tl, transcoder: fixture.transcoder)

        fixture.realtime.handlePublication(channel: "user:5", data: data)

        XCTAssertEqual(fixture.recorder.updates, [ImpulseRealtimeUpdates(channel: "user:5", tl: tl)])
        XCTAssertEqual(fixture.recorder.differences, [])
    }


    func testUpdatesTooLongRequestsAccountDifference() throws {
        let fixture: Fixture = try makeFixture()
        let tl: [UInt8] = constructorOnlyTl(ImpulseRealtime.updatesTooLongConstructorId)
        let data: Data = try publicationData(tl: tl, transcoder: fixture.transcoder)

        fixture.realtime.handlePublication(channel: "user:5", data: data)

        XCTAssertEqual(fixture.recorder.differences, [.account(.updatesTooLong)])
        XCTAssertEqual(fixture.recorder.updates, [])
    }


    func testUndecodableEnvelopeOnChannelLaneRequestsAccountDifference() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handlePublication(channel: "channel:9", data: Data("not json".utf8))

        XCTAssertEqual(fixture.recorder.differences, [.account(.publicationDecodeFailed)])
        XCTAssertEqual(fixture.recorder.updates, [])
    }


    func testUndecodableProtoRequestsAccountDifference() throws {
        let fixture: Fixture = try makeFixture()
        let envelope: ImpulseEnvelope = ImpulseEnvelope.ptsLess(type: 9, date: 1700000000, body: Data([0xFF, 0xFF, 0xFF]))
        let data: Data = try envelope.jsonData()

        fixture.realtime.handlePublication(channel: "user:5", data: data)

        XCTAssertEqual(fixture.recorder.differences, [.account(.publicationDecodeFailed)])
        XCTAssertEqual(fixture.recorder.updates, [])
    }


    func testLegacySessionRevokedArrayIsNotAnUpdateOrADifference() throws {
        let fixture: Fixture = try makeFixture()
        let data: Data = Data("[{\"event_type\":\"session.revoked\"}]".utf8)

        fixture.realtime.handlePublication(channel: "user:5", data: data)

        XCTAssertEqual(fixture.recorder.differences, [])
        XCTAssertEqual(fixture.recorder.updates, [])
    }


    func testOnlyUpdatesAndUpdatesTooLongAreRegularBodies() throws {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let updateIds: Set<UInt32> = Set(mapping.constructors(ofType: ImpulseRealtime.updatesTypeName).map { (constructor: ImpulseMappingConstructor) -> UInt32 in
            return constructor.id
        })
        let peer: ImpulseMappingConstructor = try XCTUnwrap(mapping.constructors(ofType: "Peer").first)

        XCTAssertEqual(
            ImpulseRealtime.classify(tl: constructorOnlyTl(ImpulseRealtime.updatesTooLongConstructorId), updateConstructorIds: updateIds),
            .updatesTooLong
        )
        XCTAssertEqual(
            ImpulseRealtime.classify(tl: constructorOnlyTl(peer.id), updateConstructorIds: updateIds),
            .unexpected
        )
        XCTAssertEqual(ImpulseRealtime.classify(tl: [0x01, 0x02], updateConstructorIds: updateIds), .unexpected)
    }
}
