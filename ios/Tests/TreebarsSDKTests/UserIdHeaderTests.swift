import XCTest
@testable import TreebarsSDK

/**
 What `X-Treebars-User-Id` carries for an account id: percent-encoded UTF-8, which the server decodes,
 so an account id no raw header could carry, such as "用户7", arrives intact. The twin of Kotlin's
 `UserIdHeaderTest`, with the same cases.
 */
final class UserIdHeaderTests: XCTestCase {

    func testAnAccountIdNoHeaderCanCarryRawIsSentPercentEncoded() {
        // Byte for byte what JavaScript's `encodeURIComponent` writes, which is the encoding the server reads.
        XCTAssertEqual(BackendClient.userIdHeaderValue("José 用户+42@x"), "Jos%C3%A9%20%E7%94%A8%E6%88%B7%2B42%40x")
    }

    func testWhatIsAlreadySafeIsSentAsItself() {
        XCTAssertEqual(BackendClient.userIdHeaderValue("user_42"), "user_42")
        XCTAssertEqual(BackendClient.userIdHeaderValue("a.b-c_d~e"), "a.b-c_d~e")
    }

    func testAPercentSignIsEncodedSoItCannotBeReadAsAnEscape() {
        XCTAssertEqual(BackendClient.userIdHeaderValue("50%off"), "50%25off")
    }

    func testEveryValueIsPlainPrintableASCII() {
        for id in ["José", "用户", "party 🎉", "tab\there", "line\nbreak"] {
            let value = BackendClient.userIdHeaderValue(id) ?? ""
            XCTAssertFalse(value.isEmpty, id)
            XCTAssertTrue(value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }, "\(id) -> \(value)")
        }
    }
}
