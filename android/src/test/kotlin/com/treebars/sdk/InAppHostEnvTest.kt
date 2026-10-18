package com.treebars.sdk

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The host's half of bridge 2, held to the cases every SDK runs (`in-app-host.json`): where a strip's WebView goes, and
 * what a page is told about its screen — on first draw, after a turn, with the keyboard up and down — as the text the
 * page actually reads. Robolectric only for org.json, which the plain JVM stubs out.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class InAppHostEnvTest {

    private fun fixture(): JSONObject =
        JSONObject(requireNotNull(javaClass.classLoader?.getResource("bridge/in-app-host.json")) { "bridge/in-app-host.json is missing" }.readText())

    private fun insets(json: JSONObject) = HostInsets(json.getDouble("top"), json.getDouble("right"), json.getDouble("bottom"), json.getDouble("left"))

    @Test
    fun everyStripGoesWhereTheReferencePutsIt() {
        val cases = fixture().getJSONArray("strips")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val input = case.getJSONObject("input")
            val window = input.getJSONObject("window")
            val box = InAppHostEnv.stripBox(
                window.getDouble("width"),
                window.getDouble("height"),
                insets(input.getJSONObject("safe")),
                input.getString("edge"),
                input.getBoolean("floating"),
                if (input.isNull("contentHeight")) null else input.getDouble("contentHeight"),
                input.optDouble("offset", 0.0),
            )
            val expected = case.getJSONObject("box")
            val name = case.getString("name")
            assertEquals("$name: x", expected.getDouble("x"), box.x, 0.001)
            assertEquals("$name: y", expected.getDouble("y"), box.y, 0.001)
            assertEquals("$name: w", expected.getDouble("w"), box.w, 0.001)
            assertEquals("$name: h", expected.getDouble("h"), box.h, 0.001)
        }
    }

    @Test
    fun everyEnvironmentReadsByteForByteAsTheReferenceWritesIt() {
        val cases = fixture().getJSONArray("envs")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val input = case.getJSONObject("input")
            val window = input.getJSONObject("window")
            val keyboard = input.getJSONObject("keyboard")
            val frame = input.optJSONObject("frame")?.let { HostRect(it.getDouble("x"), it.getDouble("y"), it.getDouble("w"), it.getDouble("h")) }
            val env = InAppHostEnv.env(
                host = input.getString("host"),
                device = input.getString("device"),
                theme = input.getString("theme"),
                textScale = input.getDouble("textScale"),
                shown = input.getBoolean("shown"),
                width = window.getDouble("width"),
                height = window.getDouble("height"),
                safe = insets(input.getJSONObject("safe")),
                frame = frame,
                keyboardHeight = keyboard.getDouble("height"),
                keyboardMs = keyboard.getDouble("ms"),
            )
            val name = case.getString("name")
            assertEquals(name, case.getString("json"), InAppHostEnv.json(env))
            assertEquals(name, case.getString("style"), InAppHostEnv.style(env))
            assertEquals(name, case.getString("attributes"), InAppHostEnv.attributes(env))
            assertEquals(name, InAppHtmlBridgeTest.env(case.getJSONObject("env")), env)
        }
    }

    @Test
    fun aPresentationIsReadAndOneThatIsNotAnObjectIsNone() {
        val content = parseInAppContent(
            JSONObject("""{"surface":"overlay","layout":"sheet","body_mode":"html","html":"<p>x</p>","trigger":{"kind":"immediate"},"presentation":{"bridge":2,"mode":"stage","dismissible":false,"back_steps":true,"status_bar":"light"}}"""),
        )
        assertEquals(InAppPresentation(bridge = 2, mode = "stage", dismissible = false, backSteps = true, statusBar = "light"), content.presentation)
        assertNull(parseInAppContent(JSONObject("""{"surface":"overlay","layout":"modal","trigger":{"kind":"immediate"},"presentation":"stage"}""")).presentation)
    }
}
