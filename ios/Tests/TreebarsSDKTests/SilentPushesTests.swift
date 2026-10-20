#if canImport(UIKit)
import UIKit
import XCTest
@testable import TreebarsSDK

/// The silent push that says an in-app message is waiting reaches the SDK through the app delegate, with no code in the
/// app. Without it an app that never forwarded the push — every React Native app among them — showed a test, or a
/// message sent to show at once, only after it was opened again.
final class SilentPushesTests: XCTestCase {
    private typealias Completion = @convention(block) (UIBackgroundFetchResult) -> Void
    // The application argument is passed through untouched, so any object stands in for it here.
    private typealias Implementation = @convention(c) (AnyObject, Selector, AnyObject, NSDictionary, Completion) -> Void
    private let selector = #selector(UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:))

    private func deliver(_ info: [String: Any], to target: AnyObject) -> UIBackgroundFetchResult? {
        guard let method = class_getInstanceMethod(type(of: target), selector) else { return nil }
        let call = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        var answered: UIBackgroundFetchResult?
        call(target, selector, NSObject(), info as NSDictionary, { answered = $0 })
        return answered
    }

    func testTheSyncPushIsTheSdksAndEveryOtherPushStillReachesTheAppsOwnAnswer() {
        SilentPushes.install(on: AppAnswers.self)
        let delegate = AppAnswers()

        XCTAssertEqual(deliver(["treebars_sync": "in_app", "aps": ["content-available": 1]], to: delegate), .newData)
        XCTAssertEqual(delegate.heard, 0, "the sync push is answered by the SDK and not passed on")

        XCTAssertEqual(deliver(["aps": ["content-available": 1], "from": "another library"], to: delegate), .failed)
        XCTAssertEqual(delegate.heard, 1, "a push that is not the SDK's reaches what answered before")
    }

    func testADelegateWithNoAnswerOfItsOwnGetsOne() {
        SilentPushes.install(on: NoAnswer.self)
        XCTAssertEqual(deliver(["treebars_sync": "in_app"], to: NoAnswer()), .newData)
        XCTAssertEqual(deliver(["other": "push"], to: NoAnswer()), .noData)
    }

    func testInstallingTwiceAnswersOnce() {
        SilentPushes.install(on: Twice.self)
        SilentPushes.install(on: Twice.self)
        let delegate = Twice()
        XCTAssertEqual(deliver(["other": "push"], to: delegate), .failed)
        XCTAssertEqual(delegate.heard, 1)
    }
}

private final class AppAnswers: NSObject, UIApplicationDelegate {
    var heard = 0
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        heard += 1
        completionHandler(.failed)
    }
}

private final class NoAnswer: NSObject, UIApplicationDelegate {}

private final class Twice: NSObject, UIApplicationDelegate {
    var heard = 0
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        heard += 1
        completionHandler(.failed)
    }
}
#endif
