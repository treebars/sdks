import XCTest
@testable import TreebarsSDK

/**
 Adopting an identity a wrapper is handing down, and refusing to overwrite one this core already has.

 A wrapper whose JavaScript side kept `device_id`, `fetch_secret`, `first_seen_at` and the two
 user keys in AsyncStorage — a manifest file under `Documents/RCTAsyncLocalStorage_V1` here, a
 SQLite database on Android, neither of which this core can read — reads its own store and passes
 the values in. If that path is wrong, nothing reports it:

 - **A missed fetch secret** means the device reads `/v1/in-app` and `/v1/notifications` with a
   new secret instead of the one it has been using.
 - **A missed `device_id`** splits a person's history and orphans their push token and inbox.
 - **A missed `first_seen_at`** reports `is_first_launch: true` on every existing install at
   once, firing any onboarding campaign filtered on it.

 The second test is what makes this safe to call on every launch rather than only the first,
 which is the difference between an integration a wrapper can get right and one it has to
 remember to stop doing.
 */
final class AdoptionTests: XCTestCase {

    private static let keys = [
        "treebars.device_id",
        "treebars.fetch_secret",
        "treebars.first_seen_at",
        "treebars.signed_in_user",
        "treebars.identified_user",
        "treebars.in_app_ledger",
    ]

    private var directory: URL!

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        DeviceInfo.identityStore = DeviceIdentityStore(directory: directory)
        DeviceInfo.forgetResolvedIdentity()
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: directory)
        DeviceInfo.identityStore = DeviceIdentityStore.standard()
        DeviceInfo.forgetResolvedIdentity()
        super.tearDown()
    }

    private func stored(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }

    func testAnEmptyStoreTakesEverythingTheWrapperHandsDown() {
        Adoption(
            deviceId: "dev_from_js",
            fetchSecret: "secret_from_js",
            firstSeenAt: "2020-01-01T00:00:00.000Z",
            signedInUser: "user_9",
            identifiedUser: "user_9",
            inAppLedgerJson: #"{"done":{"del_1":true},"shown":{}}"#
        ).apply()

        // The id and its secret go to the identity store as one pair, and never to UserDefaults.
        XCTAssertEqual(DeviceInfo.getDeviceId(), "dev_from_js")
        XCTAssertEqual(DeviceInfo.getFetchSecret(), "secret_from_js")
        XCTAssertNil(stored("treebars.device_id"))
        XCTAssertNil(stored("treebars.fetch_secret"))
        XCTAssertEqual(stored("treebars.first_seen_at"), "2020-01-01T00:00:00.000Z")
        XCTAssertEqual(stored("treebars.signed_in_user"), "user_9")
        XCTAssertEqual(stored("treebars.identified_user"), "user_9")
        XCTAssertEqual(stored("treebars.in_app_ledger"), #"{"done":{"del_1":true},"shown":{}}"#)
    }

    /*
     * The asymmetry that makes this safe. A wrapper passes these unconditionally on every
     * launch; a stale copy it keeps handing down cannot overwrite what this device has since
     * decided for itself.
     */
    func testAStoreThatAlreadyAnsweredKeepsItsOwnAnswer() {
        DeviceInfo.identityStore?.save(DeviceIdentity(id: "dev_native_owns_this", secret: "secret_native_owns_this"))
        UserDefaults.standard.set("2019-06-01T00:00:00.000Z", forKey: "treebars.first_seen_at")

        Adoption(deviceId: "dev_from_js", fetchSecret: "secret_from_js", firstSeenAt: "2020-01-01T00:00:00.000Z").apply()

        XCTAssertEqual(DeviceInfo.getDeviceId(), "dev_native_owns_this")
        XCTAssertEqual(DeviceInfo.getFetchSecret(), "secret_native_owns_this")
        XCTAssertEqual(stored("treebars.first_seen_at"), "2019-06-01T00:00:00.000Z")
    }

    /*
     * The id and its secret travel as one pair. An id handed down without its secret keeps the id
     * and gets a fresh secret, since a wrapper that never had one never sent one; a secret without
     * an id is nothing.
     */
    func testTheIdAndItsSecretTravelAsOnePair() {
        Adoption(deviceId: "dev_from_js").apply()
        XCTAssertEqual(DeviceInfo.getDeviceId(), "dev_from_js")
        XCTAssertEqual(DeviceInfo.getFetchSecret().count, 64)
    }

    func testASecretWithoutAnIdAdoptsNothing() {
        Adoption(fetchSecret: "secret_from_js").apply()
        XCTAssertEqual(DeviceInfo.identityStore?.load(), .absent)
    }

    func testNothingToAdoptWritesNothing() {
        Adoption().apply()

        XCTAssertEqual(DeviceInfo.identityStore?.load(), .absent)
        XCTAssertNil(stored("treebars.first_seen_at"))
    }

    /*
     * An empty string is what a wrapper hands down when its own store answered "nothing here",
     * and it must not be mistaken for a value: a device id of "" is worse than none, because
     * the key would then read as answered forever.
     */
    func testAnEmptyStringIsNothingNotAValue() {
        Adoption(deviceId: "", fetchSecret: "", firstSeenAt: "").apply()

        XCTAssertEqual(DeviceInfo.identityStore?.load(), .absent)
        XCTAssertNil(stored("treebars.first_seen_at"))
    }

    /*
     * The device id is what everything else hangs off, so the assertion that matters most is
     * that adoption actually reaches the accessor rather than only the store.
     */
    func testAnAdoptedDeviceIdIsWhatTheSDKThenReports() {
        Adoption(deviceId: "dev_adopted_from_js").apply()
        XCTAssertEqual(DeviceInfo.getDeviceId(), "dev_adopted_from_js")
    }
}
