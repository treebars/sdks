import Foundation

/**
 One formatter for every timestamp this SDK writes, and it emits fractional seconds.

 Every write site uses it — the event `timestamp`, the batch's `sent_at`, `first_seen_at`, and the
 synthetic `read_at` on a locally-marked notification. A bare `ISO8601DateFormatter()` has no
 `.withFractionalSeconds`, and whole seconds are not enough: a twenty-event batch routinely fits
 inside one second, and two events in the same second could not be ordered by the field that exists
 to order them. Android stamps milliseconds too, so both platforms sort the same way.

 The parsing sites keep a tolerant two-formatter fallback deliberately. Writing is where a single
 spelling matters; reading has to accept whatever a server or an older build sent.
 */
enum Iso8601 {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func now() -> String { string(from: Date()) }

    /// For an event stamped into a moment that has already passed; see `session_end`.
    static func string(from date: Date) -> String { formatter.string(from: date) }

    /**
     Epoch milliseconds for a stamp this SDK wrote, or nil for anything else.

     Android's `Iso8601.parseOrNull`, and it exists for the same one caller: the install's own age,
     which bounds a deferred deep link. Both formats are tried because `first_seen_at` has been
     written by more than one build of this SDK, and an install whose stamp does not parse would
     silently never receive a link it was owed.
     */
    static func millisOrNil(_ text: String) -> Int64? {
        let date = formatter.date(from: text) ?? withoutFractional.date(from: text)
        guard let date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static let withoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
