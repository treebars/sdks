package com.treebars.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Reading a timestamp is tolerant; writing one is exact.
 *
 * `2020-01-01T00:00:00Z`, with no milliseconds, has to parse: `parseOrNull` turns a parse
 * failure into null, which none of its callers read as "unknown". An `expires_at` that fails
 * to parse is a message that never expires; a `last_shown_at` that fails is a minimum gap
 * that has never elapsed. Both would fail open, silently, toward showing somebody more than
 * the rules allow.
 *
 * The server writes milliseconds today. That is a fact about the server rather than a
 * property of the wire, and a parser that depends on it is one change away from the failure
 * above.
 */
class Iso8601Test {

    @Test
    fun `a timestamp with milliseconds parses, which is the form everything sends today`() {
        assertEquals(1577836800123L, Iso8601.parseOrNull("2020-01-01T00:00:00.123Z"))
    }

    @Test
    fun `a timestamp without milliseconds parses too`() {
        assertEquals(1577836800000L, Iso8601.parseOrNull("2020-01-01T00:00:00Z"))
    }

    @Test
    fun `what it writes is what it reads, at whole seconds and otherwise`() {
        val whole = 1577836800000L
        assertEquals(whole, Iso8601.parseOrNull(Iso8601.at(whole)))
        val fractional = 1577836800123L
        assertEquals(fractional, Iso8601.parseOrNull(Iso8601.at(fractional)))
    }

    @Test
    fun `genuine rubbish is still null, because callers treat that as an absent timestamp`() {
        assertNull(Iso8601.parseOrNull(""))
        assertNull(Iso8601.parseOrNull("null"))
        assertNull(Iso8601.parseOrNull("not a date"))
        assertNull(Iso8601.parseOrNull("2020-01-01"))
    }
}
