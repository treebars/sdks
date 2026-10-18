package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

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
        assertNull(LinkResolve.candidate("https://open.example.com/", hosts))
        assertNull(LinkResolve.candidate("http://open.example.com/summer-sale", hosts))
        assertNull(LinkResolve.candidate("treebarsdemo://cart", hosts))
        assertNull(LinkResolve.candidate("", hosts))
        assertNull(LinkResolve.candidate(null, hosts))
    }

    @Test
    fun asksAboutALinkCarryingValuesWholeQueryAndAll() {
        // The link `spring` with two values: asked as it is, so the host can fill the deep link from them.
        val link = "https://open.example.com/spring/u_123/p_9?ref=mail"
        assertEquals(link, LinkResolve.candidate(link, hosts))
        assertEquals("https://open.example.com/spring/u_123/", LinkResolve.candidate("https://open.example.com/spring/u_123/", hosts))
        // An encoded slash stays inside its value, and any character a value may hold is allowed.
        assertEquals("https://open.example.com/spring/a%2Fb/caf%C3%A9", LinkResolve.candidate("https://open.example.com/spring/a%2Fb/caf%C3%A9", hosts))

        // Six values is the most a link takes; a seventh is nobody's link.
        val six = "/spring" + "/v".repeat(6)
        assertTrue(LinkResolve.isLinkPath(six))
        assertFalse(LinkResolve.isLinkPath("$six/v"))
        // A value is 1 to 256 characters once decoded.
        assertTrue(LinkResolve.isLinkPath("/spring/" + "a".repeat(256)))
        assertFalse(LinkResolve.isLinkPath("/spring/" + "a".repeat(257)))
        assertTrue(LinkResolve.isLinkPath("/spring/" + "%20".repeat(256)))
        assertTrue(LinkResolve.isLinkPath("/spring/a+b"))
        assertFalse(LinkResolve.isLinkPath("/spring//p_9"))
        assertFalse(LinkResolve.isLinkPath("/spring/u_123//"))
        assertFalse(LinkResolve.isLinkPath("/spring/%zz"))
        // The key keeps its own shape, values or not.
        assertFalse(LinkResolve.isLinkPath("/spr.ing/u_123"))
        assertFalse(LinkResolve.isLinkPath("/" + "k".repeat(65)))
        assertFalse(LinkResolve.isLinkPath("/p/summer-sale/u_123"))
        assertFalse(LinkResolve.isLinkPath("spring"))
        assertFalse(LinkResolve.isLinkPath(""))
    }

    @Test
    fun asksTheHostTheWholeAddressAndReadsItsAnswer() {
        // A bare socket, because what is pinned is the request line and the header as they leave the device.
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        var head: List<String> = emptyList()
        val host = thread(isDaemon = true) {
            server.accept().use { socket ->
                val reader = socket.getInputStream().bufferedReader()
                head = generateSequence { reader.readLine() }.takeWhile { it.isNotEmpty() }.toList()
                val body = """{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":"/programs/p_9"}"""
                socket.getOutputStream().write(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body".toByteArray(),
                )
            }
        }
        val resolved = LinkResolve.ask("http://127.0.0.1:${server.localPort}/spring/u_123/p_9?ref=mail", hosts)
        host.join(5_000)
        server.close()

        assertEquals(ResolvedLink("abcdefghijklmnopqrstuv", "/programs/p_9"), resolved)
        // Values and query reach the host as they arrived: they are what it fills the deep link from.
        assertEquals("GET /spring/u_123/p_9?ref=mail HTTP/1.1", head.first())
        assertTrue(head.any { it.equals("${TreebarsConstants.LINK_RESOLVE_HEADER}: android", ignoreCase = true) })
    }

    @Test
    fun anOpenOnALinkHostNamesOnlyTheLinksKey() {
        assertEquals("/spring", LinkResolve.openedPath("/spring/u_123/p_9", "open.example.com", hosts))
        assertEquals("/spring", LinkResolve.openedPath("/spring", "OPEN.example.com", hosts))
        assertEquals("/p/spring", LinkResolve.openedPath("/p/spring/u_123", "open.example.com", hosts))
        assertEquals("", LinkResolve.openedPath("", "open.example.com", hosts))
        // Anywhere else the path is the app's own, and stays.
        assertEquals("/product/TRS-001", LinkResolve.openedPath("/product/TRS-001", "shop.example.com", hosts))
        assertEquals("/cart", LinkResolve.openedPath("/cart", "cart", hosts))
        assertEquals("/cart", LinkResolve.openedPath("/cart", null, hosts))
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
    fun aWebsiteOnlyLinkGoesToTheBrowserAndHandsTheAppNoPath() {
        assertEquals(
            ResolvedLink("abcdefghijklmnopqrstuv", null, "https://acme.example/programs/p_9?u=u_123"),
            LinkResolve.parse("""{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":null,"web_url":"https://acme.example/programs/p_9?u=u_123"}""", hosts),
        )
        // A path beside a website is never handed on: the link goes to the website.
        assertNull(LinkResolve.parse("""{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":"/cart","web_url":"https://acme.example/"}""", hosts)?.deepLinkPath)
        // No website named: the answer every link without one gives.
        assertEquals(
            ResolvedLink("abcdefghijklmnopqrstuv", "/cart"),
            LinkResolve.parse("""{"click_id":"abcdefghijklmnopqrstuv","deep_link_path":"/cart","web_url":null}""", hosts),
        )
    }

    @Test
    fun aBrowserIsOnlySentToAnHttpsWebsiteThatIsNotALinkHost() {
        // A link host would open this app again; anything but https is not a website.
        for (bad in listOf("https://open.example.com/spring", "https://OPEN.example.com./x", "http://acme.example/", "treebarsdemo://cart", "javascript:alert(1)", "https:///x", "/programs/p_9", "")) {
            val body = JSONObject().put("click_id", "abcdefghijklmnopqrstuv").put("deep_link_path", JSONObject.NULL).put("web_url", bad).toString()
            assertEquals(bad, ResolvedLink("abcdefghijklmnopqrstuv", null), LinkResolve.parse(body, hosts))
        }
        assertNull(LinkResolve.webAddress("https://acme.example/" + "a".repeat(2048), hosts))
        assertEquals("https://acme.example/", LinkResolve.webAddress("https://acme.example/", emptySet()))
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
