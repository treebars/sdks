import XCTest
@testable import TreebarsSDK

/// Which addresses a Universal Link is asked about, and what the link host's answer is read as — the
/// same decisions `LinkResolveTest.kt` pins for Android.
final class LinkResolveTests: XCTestCase {
    private let hosts: Set<String> = ["open.example.com"]

    func testAsksAboutALinkShapedHttpsAddressAndNothingElse() {
        let link = URL(string: "https://open.example.com/summer-sale?utm_source=ads")!
        XCTAssertEqual(LinkResolve.candidate(link, hosts: hosts), link)
        XCTAssertNotNil(LinkResolve.candidate(URL(string: "https://open.example.com/tc_1/"), hosts: hosts))
        XCTAssertNotNil(LinkResolve.candidate(URL(string: "https://OPEN.example.com/summer-sale"), hosts: hosts))

        // A page-first link never opens an app; both association files exclude it.
        XCTAssertNil(LinkResolve.candidate(URL(string: "https://open.example.com/p/summer-sale"), hosts: hosts))
        // The app's own website opens it too, deeper than one segment, and is not ours to ask.
        XCTAssertNil(LinkResolve.candidate(URL(string: "https://open.example.com/products/42"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(URL(string: "https://open.example.com/"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(URL(string: "http://open.example.com/summer-sale"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(URL(string: "treebarsdemo://cart"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(nil, hosts: hosts))
    }

    func testAsksOnlyTheAppsOwnLinkHosts() {
        XCTAssertNil(LinkResolve.candidate(URL(string: "https://evil.example/summer-sale"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(URL(string: "https://open.example.com.evil.example/summer-sale"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(URL(string: "https://shop.example.com/summer-sale"), hosts: hosts))
        // No hosts given, nothing asked.
        XCTAssertNil(LinkResolve.candidate(URL(string: "https://open.example.com/summer-sale"), hosts: []))
    }

    func testTakesAHostHoweverItWasPasted() {
        for given in ["open.example.com", "OPEN.example.com", "https://open.example.com", "https://open.example.com/", " open.example.com:443 ", "open.example.com."] {
            XCTAssertEqual(LinkResolve.normalizeHost(given), "open.example.com", given)
        }
    }

    func testReadsTheClickIdAndPathAndNothingThatLacksAClickId() {
        XCTAssertEqual(
            LinkResolve.parse(Data(#"{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":"/product/TRS-001"}"#.utf8)),
            ResolvedLink(clickId: "abcdefghijklmnopqrstuv", deepLinkPath: "/product/TRS-001")
        )
        XCTAssertEqual(
            LinkResolve.parse(Data(#"{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":null}"#.utf8)),
            ResolvedLink(clickId: "abcdefghijklmnopqrstuv", deepLinkPath: nil)
        )
        XCTAssertNil(LinkResolve.parse(Data(#"{"deep_link_path":"/cart"}"#.utf8)))
        XCTAssertNil(LinkResolve.parse(Data("<!doctype html><title>Shop</title>".utf8)))
    }

    func testKeepsTheClickButNotAPathThatIsNotOne() throws {
        // Handed to the app to route on: a URL here would make the link an open redirect out of it.
        for bad in ["https://evil.example/x", "//evil.example/x", "intent://x", "cart", "/a\\b", ""] {
            let body = try JSONSerialization.data(withJSONObject: ["click_id": "abcdefghijklmnopqrstuv", "deep_link_path": bad])
            XCTAssertEqual(LinkResolve.parse(body), ResolvedLink(clickId: "abcdefghijklmnopqrstuv", deepLinkPath: nil), bad)
        }
    }
}
