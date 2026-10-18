import XCTest
@testable import TreebarsSDK

/**
 The screen an event is stamped with is the screen current when the app logged it.

 `log` returns at once and the event is built later, on a Task. A `screen` call made in between
 must not reach back into an event logged before it: that event happened on the previous screen,
 and a report broken down by `screen_name` would otherwise depend on how soon the Task ran — which
 differs between devices, and between this SDK and the Android one, which reads the screen on the
 calling thread.

 On an instance of its own over a session store and a queue file of its own, as `ContextTokenTests`
 explains: `shared` initializes once per process.
 */
final class ScreenStampTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!
    private var queueFile = ""
    private var queue: EventQueue!
    private var identityDirectory: URL!

    override func setUp() {
        super.setUp()
        suite = "treebars.screen-stamp.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        queueFile = "treebars-queue-screen-stamp-\(UUID().uuidString).json"
        queue = EventQueue(filename: queueFile)
        identityDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        DeviceInfo.identityStore = DeviceIdentityStore(directory: identityDirectory)
        DeviceInfo.forgetResolvedIdentity()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        EventQueue.forget(filename: queueFile)
        try? FileManager.default.removeItem(at: identityDirectory)
        DeviceInfo.identityStore = DeviceIdentityStore.standard()
        DeviceInfo.forgetResolvedIdentity()
        super.tearDown()
    }

    private func sdk() -> Treebars {
        let core = Treebars(sessionManager: SessionManager(defaults: defaults), queue: queue)
        core.writeKey = "pk_test_screen_stamp"
        return core
    }

    /// Every Task the calls started, finished — what `flush()` waits for before it uploads.
    private func settle(_ core: Treebars) async {
        for task in core.recording.snapshot() { await task.value }
    }

    /// The one queued event named `name`. Found by name, because two Tasks are not ordered against each other.
    private func queued(_ name: String) async -> [String: Any]? {
        await queue.peek(100).first { $0["event_name"] as? String == name }
    }

    func testAnEventLoggedBeforeTheNextScreenCarriesTheScreenItWasLoggedOn() async {
        let core = sdk()
        core.recordScreen("Home")
        core.record("product_view", properties: ["sku": "sku-1"])
        // In the same breath, as a navigator reports the route it has just moved to.
        core.recordScreen("Product")
        await settle(core)

        let view = await queued("product_view")
        XCTAssertEqual(view?["screen_name"] as? String, "Home")
    }

    func testAScreenViewCarriesTheScreenItNamesAndThePreviousOne() async {
        let core = sdk()
        core.recordScreen("Home")
        core.recordScreen("Product")
        await settle(core)

        let views = await queue.peek(100).filter { $0["event_name"] as? String == "screen_view" }
        let product = views.first { ($0["properties"] as? [String: Any])?["screen_name"] as? String == "Product" }
        XCTAssertEqual(product?["screen_name"] as? String, "Product")
        XCTAssertEqual((product?["properties"] as? [String: Any])?["previous_screen"] as? String, "Home")
    }
}
