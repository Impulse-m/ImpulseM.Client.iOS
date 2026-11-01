import Foundation
import XCTest
import SwiftCentrifuge
@testable import ImpulseTransport


/// Records what the socket reports to the realtime client.
private final class ImpulseCentrifugeSocketListenerDouble: ImpulseRealtimeSocketListener {
    private(set) var reconnects: Int = 0
    private(set) var serverChannels: [String] = []
    private(set) var serverPayloads: [Data] = []


    func handleSubscribed(
        channel: String,
        recovered: Bool,
        wasRecovering: Bool
    ) {
    }


    func handleUnsubscribed(
        channel: String,
        code: Int
    ) {
    }


    func handlePublication(
        channel: String,
        data: Data
    ) {
    }


    func handleServerPublication(
        channel: String,
        data: Data
    ) {
        serverChannels.append(channel)
        serverPayloads.append(data)
    }


    func handleReconnected() {
        reconnects += 1
    }
}


final class ImpulseCentrifugeSocketTests: XCTestCase {
    private struct Fixture {
        let client: CentrifugeClient
        let socket: ImpulseCentrifugeSocket
        let listener: ImpulseCentrifugeSocketListenerDouble
    }


    private func makeFixture() -> Fixture {
        let client: CentrifugeClient = ImpulseUpdateSocketCarrier.makeClient(
            endpoint: "wss://realtime.test.invalid/connection/websocket"
        )
        let socket: ImpulseCentrifugeSocket = ImpulseCentrifugeSocket(client: client)
        let listener: ImpulseCentrifugeSocketListenerDouble = ImpulseCentrifugeSocketListenerDouble()
        socket.listener = listener
        return Fixture(client: client, socket: socket, listener: listener)
    }


    private func connected(_ fixture: Fixture) {
        fixture.socket.onConnected(fixture.client, CentrifugeConnectedEvent(client: "client-1"))
    }


    func testSocketBecomesTheDelegateOfItsClient() {
        let fixture: Fixture = makeFixture()

        XCTAssertTrue(fixture.client.delegate === fixture.socket)
    }


    func testFirstConnectOfASocketIsNotAReconnect() {
        let fixture: Fixture = makeFixture()

        connected(fixture)

        XCTAssertEqual(fixture.listener.reconnects, 0)
    }


    func testEachConnectAfterTheFirstIsOneReconnect() {
        let fixture: Fixture = makeFixture()

        connected(fixture)
        connected(fixture)
        connected(fixture)

        XCTAssertEqual(fixture.listener.reconnects, 2)
    }


    func testServerPublicationIsForwardedWithItsChannelAndData() {
        let fixture: Fixture = makeFixture()
        let payload: Data = Data([0x01, 0x02, 0x03])

        fixture.socket.onPublication(
            fixture.client,
            CentrifugeServerPublicationEvent(channel: "session:5:77", data: payload, offset: 0, tags: [:])
        )

        XCTAssertEqual(fixture.listener.serverChannels, ["session:5:77"])
        XCTAssertEqual(fixture.listener.serverPayloads, [payload])
    }
}
