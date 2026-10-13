import XCTest
@testable import TreebarsSDK

/**
 The two ways an app reads a remote config value, where nothing is held for the key.

 `getConfig(_:fallback:)` reads as the kind its fallback is, so one name serves a flag, text and a number — each
 its own overload, which this pins by calling them the way an app does: a call that stopped choosing the overload
 it should, or stopped compiling, fails here. A kind named with no fallback answers `nil`, never a value made up
 for it. What a read answers once values are held is the shared scenarios'.
 */
final class ConfigReadTests: XCTestCase {

    func testAReadAnswersTheFallbackItWasGivenAsTheKindTheFallbackIs() {
        let flag: Bool = Treebars.getConfig("read_test_flag", fallback: false)
        let text: String = Treebars.getConfig("read_test_headline", fallback: "Welcome")
        let whole: Int = Treebars.getConfig("read_test_limit", fallback: 25)
        let decimal: Double = Treebars.getConfig("read_test_ratio", fallback: 2.5)
        let empty: String = Treebars.getConfig("read_test_headline", fallback: "")

        XCTAssertEqual(flag, false)
        XCTAssertEqual(text, "Welcome")
        XCTAssertEqual(whole, 25)
        XCTAssertEqual(decimal, 2.5)
        // Empty text is still text: a fallback for "nothing to show yet".
        XCTAssertEqual(empty, "")
        // A literal picks the overload it reads as, with no annotation to help it.
        XCTAssertEqual(Treebars.getConfig("read_test_limit", fallback: 7), 7)
        XCTAssertEqual(Treebars.getConfig("read_test_ratio", fallback: 0.5), 0.5)
        XCTAssertTrue(Treebars.getConfig("read_test_flag", fallback: true))
    }

    func testAKindNamedWithNoFallbackAnswersNilUntilAValueIsHeld() {
        XCTAssertNil(Treebars.getConfigBoolean("read_test_flag"))
        XCTAssertNil(Treebars.getConfigString("read_test_headline"))
        XCTAssertNil(Treebars.getConfigNumber("read_test_limit"))
        XCTAssertNil(Treebars.getConfigJson("read_test_layout"))
        // And with one, the fallback, as before.
        XCTAssertEqual(Treebars.getConfigBoolean("read_test_flag", fallback: true), true)
        XCTAssertEqual(Treebars.getConfigString("read_test_headline", fallback: "x"), "x")
        XCTAssertEqual(Treebars.getConfigNumber("read_test_limit", fallback: 1.5), 1.5)
        XCTAssertEqual(Treebars.getConfigJson("read_test_layout", fallback: "{}"), "{}")
    }
}
