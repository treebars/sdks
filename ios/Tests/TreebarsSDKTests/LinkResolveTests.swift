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
        XCTAssertNil(LinkResolve.candidate(URL(string: "https://open.example.com/"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(URL(string: "http://open.example.com/summer-sale"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(URL(string: "treebarsdemo://cart"), hosts: hosts))
        XCTAssertNil(LinkResolve.candidate(nil, hosts: hosts))
    }

    func testAsksAboutALinkCarryingValuesWholeQueryAndAll() {
        // The link `spring` with two values: asked as it is, so the host can fill the deep link from them.
        let link = URL(string: "https://open.example.com/spring/u_123/p_9?ref=mail")!
        XCTAssertEqual(LinkResolve.candidate(link, hosts: hosts), link)
        XCTAssertNotNil(LinkResolve.candidate(URL(string: "https://open.example.com/spring/u_123/"), hosts: hosts))
        // An encoded slash stays inside its value, and any character a value may hold is allowed.
        XCTAssertNotNil(LinkResolve.candidate(URL(string: "https://open.example.com/spring/a%2Fb/caf%C3%A9"), hosts: hosts))

        // Six values is the most a link takes; a seventh is nobody's link.
        let six = "/spring" + String(repeating: "/v", count: 6)
        XCTAssertTrue(LinkResolve.isLinkPath(six))
        XCTAssertFalse(LinkResolve.isLinkPath(six + "/v"))
        // A value is 1 to 256 characters once decoded.
        XCTAssertTrue(LinkResolve.isLinkPath("/spring/" + String(repeating: "a", count: 256)))
        XCTAssertFalse(LinkResolve.isLinkPath("/spring/" + String(repeating: "a", count: 257)))
        XCTAssertTrue(LinkResolve.isLinkPath("/spring/" + String(repeating: "%20", count: 256)))
        XCTAssertFalse(LinkResolve.isLinkPath("/spring//p_9"))
        XCTAssertFalse(LinkResolve.isLinkPath("/spring/u_123//"))
        XCTAssertFalse(LinkResolve.isLinkPath("/spring/%zz"))
        // The key keeps its own shape, values or not.
        XCTAssertFalse(LinkResolve.isLinkPath("/spr.ing/u_123"))
        XCTAssertFalse(LinkResolve.isLinkPath("/" + String(repeating: "k", count: 65)))
        XCTAssertFalse(LinkResolve.isLinkPath("/p/summer-sale/u_123"))
        XCTAssertFalse(LinkResolve.isLinkPath("spring"))
        XCTAssertFalse(LinkResolve.isLinkPath(""))
    }

    func testAsksTheHostTheWholeAddressAndReadsItsAnswer() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkHostProtocol.self]
        let link = URL(string: "https://open.example.com/spring/u_123/p_9?ref=mail")!
        let resolved = await LinkResolve.ask(link, hosts: hosts, session: URLSession(configuration: configuration))
        XCTAssertEqual(resolved, ResolvedLink(clickId: "abcdefghijklmnopqrstuv", deepLinkPath: "/programs/p_9"))
        // Values and query reach the host as they arrived: they are what it fills the deep link from.
        XCTAssertEqual(LinkHostProtocol.asked.value?.url, link)
        XCTAssertEqual(LinkHostProtocol.asked.value?.value(forHTTPHeaderField: TreebarsConstants.linkResolveHeader), "ios")
    }

    func testAnOpenOnALinkHostNamesOnlyTheLinksKey() {
        XCTAssertEqual(LinkResolve.openedPath("/spring/u_123/p_9", host: "open.example.com", hosts: hosts), "/spring")
        XCTAssertEqual(LinkResolve.openedPath("/spring", host: "OPEN.example.com", hosts: hosts), "/spring")
        XCTAssertEqual(LinkResolve.openedPath("/p/spring/u_123", host: "open.example.com", hosts: hosts), "/p/spring")
        XCTAssertEqual(LinkResolve.openedPath("", host: "open.example.com", hosts: hosts), "")
        // Anywhere else the path is the app's own, and stays.
        XCTAssertEqual(LinkResolve.openedPath("/product/TRS-001", host: "shop.example.com", hosts: hosts), "/product/TRS-001")
        XCTAssertEqual(LinkResolve.openedPath("/cart", host: "cart", hosts: hosts), "/cart")
        XCTAssertEqual(LinkResolve.openedPath("/cart", host: nil, hosts: hosts), "/cart")
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

    func testAWebsiteOnlyLinkGoesToTheBrowserAndHandsTheAppNoPath() throws {
        let body = Data(#"{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":null,"web_url":"https://acme.example/programs/p_9?u=u_123"}"#.utf8)
        XCTAssertEqual(
            LinkResolve.parse(body, hosts: hosts),
            ResolvedLink(clickId: "abcdefghijklmnopqrstuv", deepLinkPath: nil, webURL: URL(string: "https://acme.example/programs/p_9?u=u_123"))
        )
        // A path beside a website is never handed on: the link goes to the website.
        let both = Data(#"{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":"/cart","web_url":"https://acme.example/"}"#.utf8)
        XCTAssertNil(LinkResolve.parse(both, hosts: hosts)?.deepLinkPath)
        // No website named: the answer every link without one gives.
        XCTAssertEqual(
            LinkResolve.parse(Data(#"{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":"/cart","web_url":null}"#.utf8), hosts: hosts),
            ResolvedLink(clickId: "abcdefghijklmnopqrstuv", deepLinkPath: "/cart")
        )
    }

    func testABrowserIsOnlySentToAnHttpsWebsiteThatIsNotALinkHost() throws {
        // A link host would open this app again; anything but https is not a website.
        for bad in ["https://open.example.com/spring", "https://OPEN.example.com./x", "http://acme.example/", "treebarsdemo://cart", "javascript:alert(1)", "https:///x", "/programs/p_9", ""] {
            let body = try JSONSerialization.data(withJSONObject: ["click_id": "abcdefghijklmnopqrstuv", "deep_link_path": NSNull(), "web_url": bad])
            XCTAssertEqual(LinkResolve.parse(body, hosts: hosts), ResolvedLink(clickId: "abcdefghijklmnopqrstuv", deepLinkPath: nil), bad)
        }
        XCTAssertNil(LinkResolve.webAddress("https://acme.example/" + String(repeating: "a", count: 2048), hosts: hosts))
        XCTAssertNotNil(LinkResolve.webAddress("https://acme.example/", hosts: []))
    }

    func testKeepsTheClickButNotAPathThatIsNotOne() throws {
        // Handed to the app to route on: a URL here would make the link an open redirect out of it.
        for bad in ["https://evil.example/x", "//evil.example/x", "intent://x", "cart", "/a\\b", ""] {
            let body = try JSONSerialization.data(withJSONObject: ["click_id": "abcdefghijklmnopqrstuv", "deep_link_path": bad])
            XCTAssertEqual(LinkResolve.parse(body), ResolvedLink(clickId: "abcdefghijklmnopqrstuv", deepLinkPath: nil), bad)
        }
    }
}

/// The link host, answering the one question `LinkResolve.ask` sends and remembering what it was asked.
final class LinkHostProtocol: URLProtocol {
    static let asked = Box<URLRequest?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "open.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.asked.value = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":"/programs/p_9"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
