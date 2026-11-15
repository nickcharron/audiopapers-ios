import XCTest
@testable import AudiopapersKit

final class OverTests: XCTestCase {
    func testOverAtTheEndFinishesIt() {
        XCTAssertTrue(Over.endsWith("what does figure three show over"))
        XCTAssertTrue(Over.endsWith("What does figure 3 show? Over."))
        XCTAssertTrue(Over.endsWith("why use dropout, over and out"))
        XCTAssertTrue(Over.endsWith("Over"))
    }

    func testOverAnywhereElseDoesnt() {
        XCTAssertFalse(Over.endsWith("is it over twenty layers"))
        XCTAssertFalse(Over.endsWith("what about overfitting"))
        XCTAssertFalse(Over.endsWith("the results are moreover"))
        XCTAssertFalse(Over.endsWith(""))
    }

    func testOverThatsPartOfAPhraseIsntTheEnd() {
        XCTAssertFalse(Over.endsWith("can you go over"))
        XCTAssertFalse(Over.endsWith("should they start over"))
        XCTAssertTrue(Over.endsWith("can you go over the results over"))
        XCTAssertTrue(Over.endsWith("can you go over over"))
    }

    func testStripsOnlyTheFinishingOver() {
        XCTAssertEqual(Over.strip("What does figure 3 show? Over."), "What does figure 3 show?")
        XCTAssertEqual(Over.strip("can you go over the results, over"), "can you go over the results")
        XCTAssertEqual(Over.strip("can you go over"), "can you go over")
        XCTAssertEqual(Over.strip("over"), "")
    }

    func testJoinsStretchesOfSpeech() {
        XCTAssertEqual(Over.join("what does the", " residual block do"), "what does the residual block do")
        XCTAssertEqual(Over.join("", "over"), "over")
        XCTAssertEqual(Over.join("", " "), "")
    }
}
