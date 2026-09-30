import XCTest
@testable import TreebarsSDK

/// Which addresses the SDK will send a write key, a device secret and a signed-in account to — the
/// same table as Android's `BackendUrlTest`: https anywhere, http only to the developer's own machine
/// and network, and nothing else.
final class BackendURLTests: XCTestCase {
    func testAcceptsHttpsAnywhere() {
        XCTAssertTrue(BackendURL.allows(URL(string: "https://ingest.treebars.com")!))
        XCTAssertTrue(BackendURL.allows(URL(string: "https://ingest.example.com/")!))
        XCTAssertTrue(BackendURL.allows(URL(string: "https://10.0.0.5:8443")!))
    }

    func testAcceptsHttpToTheLocalStackOnly() {
        for local in [
            "http://localhost:5156",
            "http://127.0.0.1:5156",
            "http://[::1]:5156",
            // An mDNS name.
            "http://my-laptop.local:5156",
            // A handset on the same Wi-Fi as the development machine.
            "http://192.168.1.20:5156",
            "http://172.20.10.2:5156",
            "http://10.0.2.2:5156",
        ] {
            XCTAssertTrue(BackendURL.allows(URL(string: local)!), local)
        }
    }

    func testRefusesHttpToAnythingElse() {
        for remote in [
            "http://ingest.treebars.com",
            "http://8.8.8.8:5156",
            // Outside 172.16/12, and names that merely contain a local one.
            "http://172.32.0.1",
            "http://localhost.evil.example",
            "http://local.example.com",
            "http://192.168.1.20.nip.io",
            "http://300.1.1.1",
        ] {
            XCTAssertFalse(BackendURL.allows(URL(string: remote)!), remote)
        }
    }

    func testRefusesWhatIsNotAnAddressAtAll() {
        XCTAssertFalse(BackendURL.allows(URL(string: "ftp://ingest.treebars.com")!))
        XCTAssertFalse(BackendURL.allows(URL(string: "ingest.treebars.com")!))
    }
}
