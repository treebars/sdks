import XCTest
@testable import TreebarsSDK

/**
 `log(); flush()` sends what was just logged: the flush waits for the logs started before it, and for none started
 after. A log and a flush are otherwise two unstructured Tasks racing, and an event logged and flushed at once could
 miss that flush and wait for the next one.
 */
final class InFlightTests: XCTestCase {
    actor Order {
        var steps: [String] = []
        func add(_ step: String) { steps.append(step) }
    }

    func testAFlushWaitsForEveryLogStartedBeforeItAndNoneAfter() async {
        let inFlight = InFlight()
        let order = Order()

        inFlight.run {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await order.add("slow log")
        }
        inFlight.run { await order.add("fast log") }
        let logged = inFlight.snapshot()
        let flush = Task {
            for task in logged { await task.value }
            await order.add("flush")
        }
        inFlight.run {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await order.add("later log")
        }

        await flush.value
        let steps = await order.steps
        // The two started before the flush are both in, in whichever order they ran; the later one is not.
        XCTAssertEqual(steps.last, "flush")
        XCTAssertEqual(Set(steps.dropLast()), ["slow log", "fast log"])
    }

    func testAFinishedLogIsForgotten() async throws {
        let inFlight = InFlight()
        inFlight.run {}
        for _ in 0..<100 where !inFlight.snapshot().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(inFlight.snapshot().isEmpty)
    }
}
