import XCTest
@testable import TreebarsSDK

/*
 The host's half of bridge 2, held to the cases every SDK runs (`in-app-host.json`): where a strip's WebView goes, and
 what a page is told about its screen — on first draw, after a turn, with the keyboard up and down — as the text the page
 actually reads. The WKWebView itself is the simulator's to prove.
 */
final class InAppHostEnvTests: XCTestCase {

    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/in-app-host.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func insets(_ value: Any?) throws -> HostInsets {
        let json = try XCTUnwrap(value as? [String: Any])
        return HostInsets(top: number(json["top"]) ?? 0, right: number(json["right"]) ?? 0, bottom: number(json["bottom"]) ?? 0, left: number(json["left"]) ?? 0)
    }

    func testEveryStripGoesWhereTheReferencePutsIt() throws {
        let cases = try XCTUnwrap(fixture()["strips"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for spec in cases {
            let name = spec["name"] as? String ?? ""
            let input = try XCTUnwrap(spec["input"] as? [String: Any])
            let window = try XCTUnwrap(input["window"] as? [String: Any])
            let box = InAppHostEnv.stripBox(
                width: try XCTUnwrap(number(window["width"])),
                height: try XCTUnwrap(number(window["height"])),
                safe: try insets(input["safe"]),
                edge: try XCTUnwrap(input["edge"] as? String),
                floating: try XCTUnwrap(input["floating"] as? Bool),
                contentHeight: number(input["contentHeight"]),
                offset: number(input["offset"]) ?? 0
            )
            let expected = try XCTUnwrap(spec["box"] as? [String: Any])
            for (key, value) in [("x", box.x), ("y", box.y), ("w", box.w), ("h", box.h)] {
                XCTAssertEqual(value, try XCTUnwrap(number(expected[key])), accuracy: 0.001, "\(name): \(key)")
            }
        }
    }

    func testEveryEnvironmentReadsByteForByteAsTheReferenceWritesIt() throws {
        let cases = try XCTUnwrap(fixture()["envs"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for spec in cases {
            let name = spec["name"] as? String ?? ""
            let input = try XCTUnwrap(spec["input"] as? [String: Any])
            let window = try XCTUnwrap(input["window"] as? [String: Any])
            let keyboard = try XCTUnwrap(input["keyboard"] as? [String: Any])
            let frame = (input["frame"] as? [String: Any]).map {
                HostRect(x: number($0["x"]) ?? 0, y: number($0["y"]) ?? 0, w: number($0["w"]) ?? 0, h: number($0["h"]) ?? 0)
            }
            let env = InAppHostEnv.env(
                host: try XCTUnwrap(input["host"] as? String),
                device: try XCTUnwrap(input["device"] as? String),
                theme: try XCTUnwrap(input["theme"] as? String),
                textScale: try XCTUnwrap(number(input["textScale"])),
                shown: try XCTUnwrap(input["shown"] as? Bool),
                width: try XCTUnwrap(number(window["width"])),
                height: try XCTUnwrap(number(window["height"])),
                safe: try insets(input["safe"]),
                frame: frame,
                keyboardHeight: number(keyboard["height"]) ?? 0,
                keyboardMs: number(keyboard["ms"]) ?? 0
            )
            XCTAssertEqual(InAppHostEnv.json(env), spec["json"] as? String, name)
            XCTAssertEqual(InAppHostEnv.style(env), spec["style"] as? String, name)
            XCTAssertEqual(InAppHostEnv.attributes(env), spec["attributes"] as? String, name)
            XCTAssertEqual(env, try InAppHtmlBridgeTests.env(try XCTUnwrap(spec["env"] as? [String: Any])), name)
        }
    }

    func testAPresentationIsReadAndAMessageWithoutOneFallsBackToItsLayout() throws {
        let json = #"{"surface":"overlay","layout":"sheet","body_mode":"html","html":"<p>x</p>","trigger":{"kind":"immediate"},"presentation":{"bridge":2,"mode":"stage","dismissible":false,"back_steps":true,"status_bar":"light","extra":1}}"#
        let content = try JSONDecoder().decode(InAppContent.self, from: Data(json.utf8))
        XCTAssertEqual(content.presentation, InAppPresentation(bridge: 2, mode: "stage", dismissible: false, back_steps: true, status_bar: "light"))
        // A presentation that is not an object is no presentation, rather than no message.
        let broken = try JSONDecoder().decode(InAppContent.self, from: Data(#"{"surface":"overlay","layout":"modal","trigger":{"kind":"immediate"},"presentation":"stage"}"#.utf8))
        XCTAssertNil(broken.presentation)
        XCTAssertEqual(broken.layout, "modal")
    }
}
