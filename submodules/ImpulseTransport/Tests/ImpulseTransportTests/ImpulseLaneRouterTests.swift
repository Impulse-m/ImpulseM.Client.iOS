import XCTest
@testable import ImpulseTransport


/// Records the socket calls in order, and holds the listener weakly as the real socket does.
private final class ImpulseLaneSocketDouble: ImpulseRealtimeSocket {
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
private final class ImpulseLaneRecorder {
    private(set) var differences: [ImpulseDifferenceRequest] = []
    private(set) var updates: [ImpulseRealtimeUpdates] = []


    func recordDifference(_ request: ImpulseDifferenceRequest) {
        differences.append(request)
    }


    func recordUpdates(_ value: ImpulseRealtimeUpdates) {
        updates.append(value)
    }
}


final class ImpulseLaneRouterTests: XCTestCase {
    private struct Fixture {
        let mapping: ImpulseMapping
        let transcoder: ImpulseTranscoder
        let socket: ImpulseLaneSocketDouble
        let recorder: ImpulseLaneRecorder
        let realtime: ImpulseRealtime
    }


    private func makeFixture() throws -> Fixture {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let socket: ImpulseLaneSocketDouble = ImpulseLaneSocketDouble()
        let recorder: ImpulseLaneRecorder = ImpulseLaneRecorder()
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


    /// The TL bytes of a bare constructor id, with no fields.
    private func constructorOnly(_ id: UInt32) -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: id))
        return writer.toByteArray()
    }


    /// The TL bytes of an `updates` container that holds the given updates and nothing else.
    private func container(updates: [[UInt8]]) -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: ImpulseLaneRouter.updatesConstructorId))
        writer.writeInt32(value: Int32(bitPattern: ImpulseTlConstants.vector))
        writer.writeInt32(value: Int32(updates.count))
        for update: [UInt8] in updates {
            writer.writeRaw(value: update)
        }
        writer.writeInt32(value: Int32(bitPattern: ImpulseTlConstants.vector))
        writer.writeInt32(value: 0)
        writer.writeInt32(value: Int32(bitPattern: ImpulseTlConstants.vector))
        writer.writeInt32(value: 0)
        writer.writeInt32(value: 1700000000)
        writer.writeInt32(value: 0)
        return writer.toByteArray()
    }


    private func channelTooLongUpdate(channelId: Int64) -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: ImpulseLaneRouter.updateChannelTooLongConstructorId))
        writer.writeInt32(value: 0)
        writer.writeInt64(value: channelId)
        return writer.toByteArray()
    }


    private func newAuthorizationUpdate(hash: Int64) -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: 2303831023))
        writer.writeInt32(value: 0)
        writer.writeInt64(value: hash)
        return writer.toByteArray()
    }


    private func dcOptionsUpdate() -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: 2388564083))
        writer.writeInt32(value: Int32(bitPattern: ImpulseTlConstants.vector))
        writer.writeInt32(value: 0)
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


    func testLaneKindsFollowTheName() throws {
        XCTAssertEqual(ImpulseLaneRouter.kind(of: "user:5"), .user)
        XCTAssertEqual(ImpulseLaneRouter.kind(of: "channel:9"), .channel)
        XCTAssertEqual(ImpulseLaneRouter.kind(of: "session:5:77"), .session)
        XCTAssertEqual(ImpulseLaneRouter.kind(of: "identity:abc"), .identity)
        XCTAssertEqual(ImpulseLaneRouter.kind(of: "system:config"), .system)
        XCTAssertEqual(ImpulseLaneRouter.kind(of: "system:other"), .unknown)
        XCTAssertEqual(ImpulseLaneRouter.kind(of: "news:1"), .unknown)
        XCTAssertEqual(ImpulseLaneRouter.kind(of: ""), .unknown)
    }


    func testLaneNamesAreSessionAndIdentityWithTheirParts() throws {
        XCTAssertEqual(ImpulseLaneRouter.sessionLane(userId: 5, sessionHash: 77), "session:5:77")
        XCTAssertEqual(ImpulseLaneRouter.identityLane(identityId: "abc"), "identity:abc")
    }


    func testSessionSubscribesOnceAndAHashChangeReplacesTheLane() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.subscribeSessionLane(userId: 5, sessionHash: 77)
        fixture.realtime.subscribeSessionLane(userId: 5, sessionHash: 77)
        fixture.realtime.subscribeSessionLane(userId: 5, sessionHash: 78)
        fixture.realtime.dropSessionLane()

        XCTAssertEqual(fixture.socket.calls, [
            "subscribe session:5:77 true true",
            "unsubscribe session:5:77",
            "subscribe session:5:78 true true",
            "unsubscribe session:5:78",
        ])
    }


    func testIdentitySubscribesAndDrops() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.subscribeIdentityLane(identityId: "abc")
        fixture.realtime.subscribeIdentityLane(identityId: "")
        fixture.realtime.dropIdentityLane()

        XCTAssertEqual(fixture.socket.calls, [
            "subscribe identity:abc true true",
            "unsubscribe identity:abc",
        ])
    }


    func testSessionPublicationReachesTheCallHandlerDecoded() throws {
        let fixture: Fixture = try makeFixture()
        let tl: [UInt8] = container(updates: [newAuthorizationUpdate(hash: 99)])
        let data: Data = try publicationData(tl: tl, transcoder: fixture.transcoder)

        fixture.realtime.handlePublication(channel: "session:5:77", data: data)

        XCTAssertEqual(fixture.recorder.updates, [ImpulseRealtimeUpdates(channel: "session:5:77", tl: tl)])
        XCTAssertEqual(fixture.recorder.differences, [])
    }


    func testIdentityUpdateLoginTokenReachesQrLogin() throws {
        let fixture: Fixture = try makeFixture()
        let tl: [UInt8] = container(updates: [constructorOnly(1448076945)])
        let data: Data = try publicationData(tl: tl, transcoder: fixture.transcoder)

        fixture.realtime.handlePublication(channel: "identity:abc", data: data)

        XCTAssertEqual(fixture.recorder.updates, [ImpulseRealtimeUpdates(channel: "identity:abc", tl: tl)])
        XCTAssertEqual(fixture.recorder.differences, [])
    }


    func testSystemDcOptionsReachTheUpdateHandler() throws {
        let fixture: Fixture = try makeFixture()
        let tl: [UInt8] = container(updates: [dcOptionsUpdate()])
        let data: Data = try publicationData(tl: tl, transcoder: fixture.transcoder)

        fixture.realtime.handlePublication(channel: "system:config", data: data)

        XCTAssertEqual(fixture.recorder.updates, [ImpulseRealtimeUpdates(channel: "system:config", tl: tl)])
    }


    func testUnknownLaneIsIgnored() throws {
        let fixture: Fixture = try makeFixture()
        let tl: [UInt8] = container(updates: [constructorOnly(1448076945)])
        let data: Data = try publicationData(tl: tl, transcoder: fixture.transcoder)

        fixture.realtime.handlePublication(channel: "news:1", data: data)

        XCTAssertEqual(fixture.recorder.updates, [])
        XCTAssertEqual(fixture.recorder.differences, [])
    }


    func testChannelTooLongAnswersWithChannelDifference() throws {
        let fixture: Fixture = try makeFixture()
        let tl: [UInt8] = container(updates: [channelTooLongUpdate(channelId: 9)])
        let data: Data = try publicationData(tl: tl, transcoder: fixture.transcoder)

        fixture.realtime.handlePublication(channel: "channel:9", data: data)

        XCTAssertEqual(fixture.recorder.differences, [.channel(channelId: 9, reason: .updatesTooLong)])
        XCTAssertEqual(fixture.recorder.updates, [])
    }


    func testChannelTooLongOnUserLaneIsPlainUpdates() throws {
        let fixture: Fixture = try makeFixture()
        let router: ImpulseLaneRouter = ImpulseLaneRouter(mapping: fixture.mapping)
        let tl: [UInt8] = container(updates: [channelTooLongUpdate(channelId: 9)])

        XCTAssertEqual(
            router.route(channel: "user:5", tl: tl),
            .updates(ImpulseRealtimeUpdates(channel: "user:5", tl: tl))
        )
    }


    func testChannelTooLongIdIsReadOnlyFromASoleUpdate() throws {
        XCTAssertEqual(
            ImpulseLaneRouter.channelTooLongId(tl: container(updates: [channelTooLongUpdate(channelId: 9)])),
            9
        )
        XCTAssertEqual(
            ImpulseLaneRouter.channelTooLongId(tl: container(updates: [constructorOnly(1448076945)])),
            nil
        )
        XCTAssertEqual(
            ImpulseLaneRouter.channelTooLongId(tl: [0x01, 0x02]),
            nil
        )
        XCTAssertEqual(
            ImpulseLaneRouter.channelTooLongId(tl: channelTooLongUpdate(channelId: 9)),
            nil
        )
    }


    func testSessionLaneLossRequestsAccountDifference() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handleUnsubscribed(channel: "session:5:77", code: 2502)
        fixture.realtime.handleSubscribed(channel: "session:5:77", recovered: true, wasRecovering: true)

        XCTAssertEqual(fixture.recorder.differences, [.account(.subscribePositionDropped)])
    }


    func testFreshSessionSubscribeRequestsNoDifference() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handleSubscribed(channel: "session:5:77", recovered: false, wasRecovering: false)

        XCTAssertEqual(fixture.recorder.differences, [])
    }


    func testFailedSessionRecoveryRequestsNoDifference() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handleSubscribed(channel: "session:5:77", recovered: false, wasRecovering: true)

        XCTAssertEqual(fixture.recorder.differences, [])
    }


    func testIdentityLaneLossRequestsNoDifference() throws {
        let fixture: Fixture = try makeFixture()

        fixture.realtime.handleSubscribed(channel: "identity:abc", recovered: false, wasRecovering: true)

        XCTAssertEqual(fixture.recorder.differences, [])
    }


    func testNotifySettingsUpdateOnSessionLaneIsDecoded() throws {
        let fixture: Fixture = try makeFixture()
        let constructor: ImpulseMappingConstructor = try XCTUnwrap(
            fixture.mapping.constructors(ofType: "Update").first(where: { (candidate: ImpulseMappingConstructor) -> Bool in
                return candidate.predicate == "updateNotifySettings"
            })
        )
        let update: [UInt8] = try ImpulseTlSynth(mapping: fixture.mapping).constructorTl(constructor: constructor, allFlags: false)
        let tl: [UInt8] = container(updates: [update])
        let data: Data = try publicationData(tl: tl, transcoder: fixture.transcoder)

        fixture.realtime.handlePublication(channel: "session:5:77", data: data)

        XCTAssertEqual(fixture.recorder.updates, [ImpulseRealtimeUpdates(channel: "session:5:77", tl: tl)])
        XCTAssertEqual(fixture.recorder.differences, [])
    }
}
