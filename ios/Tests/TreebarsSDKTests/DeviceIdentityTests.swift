import XCTest
@testable import TreebarsSDK

/**
 One handset is one device id and one fetch secret, however many callers ask at once.

 The Android core pins the same thing. Callers that each minted their own values on a fresh
 install would each hand a different device id to an event, splitting one handset's history
 across several devices, and would each present a different fetch secret from the one on file.

 The window is real: `device_context` and the in-app sync both read the secret within
 milliseconds of each other on first launch, and the React Native bridge calls in from a
 different thread.
 */
final class DeviceIdentityTests: XCTestCase {

    private var directory: URL!

    /// A store of this test's own, so a first launch is an empty directory rather than a guess.
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        DeviceInfo.identityStore = DeviceIdentityStore(directory: directory)
        DeviceInfo.forgetResolvedIdentity()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        DeviceInfo.identityStore = DeviceIdentityStore.standard()
        DeviceInfo.forgetResolvedIdentity()
        super.tearDown()
    }

    /// A first launch again: nothing on file and nothing remembered by this process.
    private func freshInstall() {
        DeviceInfo.identityStore?.erase()
        DeviceInfo.forgetResolvedIdentity()
    }

    /// Callers at once on a store that holds nothing yet — the first-launch shape.
    ///
    /// `concurrentPerform` rather than eight `async` blocks on the global queue, and the
    /// difference decides whether this test is worth anything. Dispatching eight blocks does
    /// not guarantee eight threads: the pool spins up lazily, so the first caller can finish
    /// and write before the second even starts, and the test then passes for a reason that
    /// has nothing to do with the code under it. `concurrentPerform` blocks until every
    /// iteration is done and actually runs them in parallel.
    ///
    /// And repeated, because one race is a coin toss: without the lock, a single 16-way race
    /// reproduces the bug perhaps half the time, failing the device-id case on one run and the
    /// fetch-secret case on the next. A suite built on one race would go green over this
    /// regression about as often as it caught it — which is worse than no test, because it
    /// would be believed.
    ///
    /// Clearing the store between rounds is what makes each round a first launch. Without it
    /// only the first round races at all and the rest read a value that is already there.
    private func racing<T: Hashable>(rounds: Int = 12, _ read: @escaping () -> T) -> Set<T> {
        var worst: Set<T> = []

        for _ in 0..<rounds {
            freshInstall()

            let lock = NSLock()
            var seen: Set<T> = []
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                let value = read()
                lock.lock()
                seen.insert(value)
                lock.unlock()
            }

            if seen.count > worst.count { worst = seen }
        }

        return worst
    }

    func testConcurrentCallersGetOneDeviceId() {
        let seen = racing { DeviceInfo.getDeviceId() }

        XCTAssertEqual(
            seen.count,
            1,
            """
            Concurrent callers minted \(seen.count) device ids in one round. Every one but the last writer \
            has already been handed to an event, so this is that many devices registered for one \
            handset.
            """
        )
    }

    func testConcurrentCallersGetOneFetchSecret() {
        let seen = racing { DeviceInfo.getFetchSecret() }

        XCTAssertEqual(
            seen.count,
            1,
            """
            Concurrent callers minted \(seen.count) fetch secrets in one round. A device has to keep \
            presenting the one secret it registered, so every secret but that one is useless to it.
            """
        )
    }

    /// The mint is once, not once per caller: a second read returns what the first stored.
    func testASecondReadReturnsTheStoredValue() {
        let first = DeviceInfo.getDeviceId()
        let second = DeviceInfo.getDeviceId()

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("dev_"), "the prefix every SDK shares")
        // On file, for the next launch — and not in UserDefaults, which a backup carries elsewhere.
        XCTAssertEqual(DeviceInfo.identityStore?.load(), .found(DeviceIdentity(id: first, secret: DeviceInfo.getFetchSecret())))
        XCTAssertNil(UserDefaults.standard.string(forKey: "treebars.device_id"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "treebars.fetch_secret"))
    }

    /// The next launch reads the file rather than minting: the process forgets, the store does not.
    func testANewProcessReadsWhatTheLastOneWrote() {
        let id = DeviceInfo.getDeviceId()
        let secret = DeviceInfo.getFetchSecret()
        DeviceInfo.forgetResolvedIdentity()

        XCTAssertEqual(DeviceInfo.getDeviceId(), id)
        XCTAssertEqual(DeviceInfo.getFetchSecret(), secret)
    }

    /// Out of every backup, which is the whole point of the file.
    func testTheFileIsExcludedFromBackup() throws {
        _ = DeviceInfo.getDeviceId()
        let file = directory.appendingPathComponent(DeviceIdentityStore.fileName)
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    /// A restore onto another phone brings no file: a new device, id and secret together, never one without the other.
    func testAMissingFileIsANewDeviceNotANewSecret() {
        let before = (DeviceInfo.getDeviceId(), DeviceInfo.getFetchSecret())
        freshInstall()
        let after = (DeviceInfo.getDeviceId(), DeviceInfo.getFetchSecret())

        XCTAssertNotEqual(before.0, after.0)
        XCTAssertNotEqual(before.1, after.1)
    }

    /// A wrapper's hand-down lands only in an empty store, and a stale one cannot overwrite it.
    func testAHandDownOnlyFillsAnEmptyStore() {
        DeviceInfo.adopt(id: "dev_from_js", secret: "secret_from_js")
        XCTAssertEqual(DeviceInfo.getDeviceId(), "dev_from_js")
        XCTAssertEqual(DeviceInfo.getFetchSecret(), "secret_from_js")

        DeviceInfo.forgetResolvedIdentity()
        DeviceInfo.adopt(id: "dev_other", secret: "secret_other")
        XCTAssertEqual(DeviceInfo.getDeviceId(), "dev_from_js")
    }
}
