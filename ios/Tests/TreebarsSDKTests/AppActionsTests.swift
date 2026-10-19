import XCTest
@testable import TreebarsSDK

/*
 The app's `onAction`: the dispatcher every SDK runs, held to the shared cases (`app-action-scenarios.json`) — which
 handlers an action reaches, how long one nothing has subscribed to waits, and what is recorded about each — with a
 clock the test moves. And a push's own tap action, which reaches the same dispatcher. On the simulator: the dispatcher
 is the main actor's.
 */
@MainActor
final class AppActionsTests: XCTestCase {

    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/app-action-scenarios.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// A clock and its timers, run when the test moves it.
    private final class Clock {
        final class Timer {
            let at: TimeInterval
            let work: @MainActor () -> Void
            var cancelled = false
            init(at: TimeInterval, work: @escaping @MainActor () -> Void) {
                self.at = at
                self.work = work
            }
        }
        var now: TimeInterval = 0
        var timers: [Timer] = []

        @MainActor
        func advance(_ seconds: TimeInterval) {
            let until = now + seconds
            while let next = timers.filter({ !$0.cancelled && $0.at <= until + 1e-9 }).min(by: { $0.at < $1.at }) {
                timers.removeAll { $0 === next }
                now = next.at
                next.work()
            }
            now = until
        }
    }

    func testEveryCaseMeansWhatItMeansOnTheWeb() throws {
        let cases = try XCTUnwrap(fixture()["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for spec in cases { try run(spec) }
    }

    private func source(_ json: [String: Any]) -> AppActionSource {
        AppActionSource(kind: json["kind"] as? String ?? "", campaignId: json["campaign_id"] as? String, messageId: json["message_id"] as? String)
    }

    private func run(_ spec: [String: Any]) throws {
        let name = spec["name"] as? String ?? ""
        let clock = Clock()
        var events: [[Any]] = []
        var delivered: [[Any]] = []
        let actions = AppActions(
            track: { event, properties in events.append([event, properties]) },
            later: { seconds, work in
                let timer = Clock.Timer(at: clock.now + seconds, work: work)
                clock.timers.append(timer)
                return timer
            },
            cancel: { ($0 as? Clock.Timer)?.cancelled = true }
        )
        var subscriptions: [String: AppActionSubscription] = [:]
        for step in try XCTUnwrap(spec["steps"] as? [[String: Any]]) {
            if step.keys.contains("on") {
                let id = try XCTUnwrap(step["id"] as? String)
                // A Swift handler cannot throw; one marked as throwing records its call, and the next must still run.
                subscriptions[id] = actions.on(step["on"] as? String) { action in delivered.append([id, action.name, action.payload]) }
            } else if let off = step["off"] as? String {
                subscriptions[off]?.cancel()
            } else if let fire = step["fire"] as? [String: Any] {
                let action = AppAction(
                    name: try XCTUnwrap(fire["name"] as? String),
                    payload: fire["payload"] as? [String: Any] ?? [:],
                    source: source(try XCTUnwrap(fire["source"] as? [String: Any]))
                )
                actions.fire(action, record: step["record"] as? Bool ?? true)
            } else if let advance = (step["advance"] as? NSNumber)?.doubleValue {
                clock.advance(advance / 1000)
            }
        }
        XCTAssertEqual(json(plain(delivered)), json(plain(spec["delivered"])), "\(name): delivered")
        XCTAssertEqual(json(plain(events)), json(plain(spec["events"])), "\(name): events")
    }

    func testAPushsOwnTapActionIsReadBeforeItsDeepLink() throws {
        let tap = #"{"type":"app_action","name":"open.order","payload":{"order":"o-7"}}"#
        let info: [AnyHashable: Any] = [TreebarsConstants.richPushActionKey: tap, TreebarsConstants.richPushDeepLinkKey: "shop://orders"]
        XCTAssertEqual(PushParts.action(info, button: nil)?["name"] as? String, "open.order")
        XCTAssertEqual(PushParts.action([TreebarsConstants.richPushDeepLinkKey: "shop://orders"], button: nil)?["type"] as? String, "deep_link")
    }

    func testAnActionNameIsWhatEverySdkCallsOne() {
        for good in ["add_to_cart", "cart.open", "a", "navigate", "x9_y.z"] { XCTAssertTrue(AppActions.isName(good), good) }
        for bad in ["", "Add", "9lives", "add to cart", "_x", String(repeating: "a", count: 65)] { XCTAssertFalse(AppActions.isName(bad), bad) }
    }

    /// A JSON value as plain values, every number a Double and every flag a Bool, so `1` and `1.0` compare as JSON does.
    private func plain(_ value: Any?) -> Any {
        switch value {
        case nil, is NSNull: return NSNull()
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return number.boolValue
        case let flag as Bool: return flag
        case let number as NSNumber: return number.doubleValue
        case let text as String: return text
        case let object as [String: Any]: return object.mapValues { plain($0) }
        case let list as [Any]: return list.map { plain($0) }
        case let other?: return String(describing: other)
        }
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "<unserializable>" }
        return String(decoding: data, as: UTF8.self)
    }
}
