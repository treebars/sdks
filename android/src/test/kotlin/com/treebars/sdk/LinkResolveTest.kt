package com.treebars.sdk

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Which addresses an App Link is asked about, and what the link host's answer is read as. The request
 * itself needs a network; what is pinned is every decision around it — above all that an ordinary
 * website address the app also opens is not sent a question.
 */
@RunWith(RobolectricTestRunner::class)
class LinkResolveTest {

    private val hosts = setOf("open.example.com")

    @Test
    fun asksAboutALinkShapedHttpsAddressAndNothingElse() {
        val link = "https://open.example.com/summer-sale?utm_source=ads"
        assertEquals(link, LinkResolve.candidate(link, hosts))
        assertEquals("https://open.example.com/tc_1/", LinkResolve.candidate("https://open.example.com/tc_1/", hosts))
        assertEquals("https://OPEN.example.com/summer-sale", LinkResolve.candidate("https://OPEN.example.com/summer-sale", hosts))

        // A page-first link never opens an app; both association files exclude it.
        assertNull(LinkResolve.candidate("https://open.example.com/p/summer-sale", hosts))
        // The app's own website opens it too, deeper than one segment, and is not ours to ask.
        assertNull(LinkResolve.candidate("https://open.example.com/products/42", hosts))
        assertNull(LinkResolve.candidate("https://open.example.com/", hosts))
        assertNull(LinkResolve.candidate("http://open.example.com/summer-sale", hosts))
        assertNull(LinkResolve.candidate("treebarsdemo://cart", hosts))
        assertNull(LinkResolve.candidate("", hosts))
        assertNull(LinkResolve.candidate(null, hosts))
    }

    @Test
    fun asksOnlyTheAppsOwnLinkHosts() {
        // Another app can hand this one an intent carrying any URL; the question goes nowhere it names.
        assertNull(LinkResolve.candidate("https://evil.example/summer-sale", hosts))
        assertNull(LinkResolve.candidate("https://open.example.com.evil.example/summer-sale", hosts))
        assertNull(LinkResolve.candidate("https://shop.example.com/summer-sale", hosts))
        // No hosts given, nothing asked.
        assertNull(LinkResolve.candidate("https://open.example.com/summer-sale", emptySet()))
    }

    @Test
    fun takesAHostHoweverItWasPasted() {
        for (given in listOf("open.example.com", "OPEN.example.com", "https://open.example.com", "https://open.example.com/", " open.example.com:443 ", "open.example.com.")) {
            assertEquals(given, "open.example.com", LinkResolve.normalizeHost(given))
        }
    }

    @Test
    fun readsTheClickIdAndPathAndNothingThatLacksAClickId() {
        assertEquals(
            ResolvedLink("abcdefghijklmnopqrstuv", "/product/TRS-001"),
            LinkResolve.parse("""{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":"/product/TRS-001"}"""),
        )
        assertEquals(
            ResolvedLink("abcdefghijklmnopqrstuv", null),
            LinkResolve.parse("""{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":null}"""),
        )
        assertNull(LinkResolve.parse("""{"deep_link_path":"/cart"}"""))
        assertNull(LinkResolve.parse("<!doctype html><title>Shop</title>"))
    }

    @Test
    fun keepsTheClickButNotAPathThatIsNotOne() {
        // Handed to the app to route on: a URL here would make the link an open redirect out of it.
        for (bad in listOf("https://evil.example/x", "//evil.example/x", "intent://x", "cart", "/a\\b", "")) {
            val body = JSONObject().put("click_id", "abcdefghijklmnopqrstuv").put("deep_link_path", bad).toString()
            assertEquals(bad, ResolvedLink("abcdefghijklmnopqrstuv", null), LinkResolve.parse(body))
        }
    }
}
