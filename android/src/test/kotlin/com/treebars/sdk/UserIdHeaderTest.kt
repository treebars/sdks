package com.treebars.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What `X-Treebars-User-Id` carries for an account id: percent-encoded UTF-8, which the server decodes.
 * A raw id would be refused by OkHttp for any non-ASCII character, so a person whose account id was
 * "用户7" would read an empty in-app queue and inbox with nothing in any log. The same cases as the
 * iOS SDK's `UserIdHeaderTests` and the web SDK's `signed-identity.test.ts`.
 */
class UserIdHeaderTest {

    @Test
    fun anAccountIdNoHeaderCanCarryRawIsSentPercentEncoded() {
        // Byte for byte what `encodeURIComponent` writes, which is what `decodeURIComponent` reads on the server.
        assertEquals("Jos%C3%A9%20%E7%94%A8%E6%88%B7%2B42%40x", userIdHeaderValue("José 用户+42@x"))
    }

    @Test
    fun whatIsAlreadySafeIsSentAsItself() {
        assertEquals("user_42", userIdHeaderValue("user_42"))
        assertEquals("a.b-c_d", userIdHeaderValue("a.b-c_d"))
    }

    @Test
    fun aPercentSignIsEncodedSoItCannotBeReadAsAnEscape() {
        assertEquals("50%25off", userIdHeaderValue("50%off"))
    }

    @Test
    fun everyValueIsPlainPrintableAscii() {
        for (id in listOf("José", "用户", "party 🎉", "tab\there", "line\nbreak")) {
            val value = userIdHeaderValue(id)
            assertTrue("$id -> $value", value.all { it.code in 0x21..0x7e })
        }
    }
}
