import XCTest
@testable import TreebarsSDK

/*
 Traits a message sets before anybody signs in go on the anonymous person as a `traits_set` event, which the server
 carries into the account at sign-in, so an onboarding survey keeps the answers of exactly the people it is shown to. A
 signed-in person's go through `identify`. What a form keeps is `formKeeps`: only a declared trait, never a reserved one.
 */
final class MessageTraitsTests: XCTestCase {

    func testTraitsSetCarriesTheValuesAndTheirSortedNames() throws {
        let properties = Treebars.traitsSetProperties(["streak": 3, "first_name": "Ada"])
        XCTAssertEqual(properties["trait_keys"] as? [String], ["first_name", "streak"])
        let traits = try XCTUnwrap(properties["traits"] as? [String: Any])
        XCTAssertEqual(traits["streak"] as? Int, 3)
        XCTAssertEqual(traits["first_name"] as? String, "Ada")
        // The queue keeps an event as JSON: a place is the one object a message sets, and it has to survive that.
        let place = Treebars.traitsSetProperties(["home": ["latitude": 25.2, "longitude": 55.3]])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(place))
    }

    func testTheEventIsTheOneTheServerReserves() {
        XCTAssertEqual(Treebars.traitsSetEvent, "traits_set")
        XCTAssertTrue(TreebarsConstants.reservedEventNames.contains(Treebars.traitsSetEvent))
    }
}
