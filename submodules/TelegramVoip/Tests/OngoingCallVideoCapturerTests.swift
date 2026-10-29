import XCTest
@testable import TelegramVoip


final class OngoingCallVideoCapturerTests: XCTestCase {
    func testNewestSwitchIsTheOnlyCurrentOne() {
        let sequence: VideoInputSwitchSequence = VideoInputSwitchSequence()
        let first: UInt64 = sequence.advance()
        let second: UInt64 = sequence.advance()
        XCTAssertFalse(sequence.isCurrent(first))
        XCTAssertTrue(sequence.isCurrent(second))
    }


    func testLoneSwitchStaysCurrent() {
        let sequence: VideoInputSwitchSequence = VideoInputSwitchSequence()
        let ticket: UInt64 = sequence.advance()
        XCTAssertTrue(sequence.isCurrent(ticket))
    }


    func testLastOfManySwitchesWins() {
        let sequence: VideoInputSwitchSequence = VideoInputSwitchSequence()
        var tickets: [UInt64] = []
        for _ in 0 ..< 5 {
            tickets.append(sequence.advance())
        }
        for ticket in tickets.dropLast() {
            XCTAssertFalse(sequence.isCurrent(ticket))
        }
        XCTAssertTrue(sequence.isCurrent(tickets[4]))
    }


    func testTicketsStayCurrentUntilTheNextSwitch() {
        let sequence: VideoInputSwitchSequence = VideoInputSwitchSequence()
        let ticket: UInt64 = sequence.advance()
        XCTAssertTrue(sequence.isCurrent(ticket))
        XCTAssertTrue(sequence.isCurrent(ticket))
        _ = sequence.advance()
        XCTAssertFalse(sequence.isCurrent(ticket))
    }
}
