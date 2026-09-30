package com.treebars.sdk

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * What a sent form keeps beyond its answers: an address marked `save_as`, and an answer kept as a
 * trait only when the message declares it and the product does not keep it — the web's `formKeeps`, the same cases.
 */
@RunWith(RobolectricTestRunner::class)
class InAppFormTest {

    private fun inApp(declared: List<String>) = JSONObject(
        """
        {"surface":"overlay","layout":"modal",
         "declared":{"events":[],"traits":${declared.joinToString(",", "[", "]") { "\"$it\"" }}},
         "form":{"fields":[
           {"id":"age","kind":"number","label":"Age","trait":"age"},
           {"id":"likes","kind":"multi_choice","label":"Likes","options":["Coats","Shoes"],"trait":"likes"},
           {"id":"email","kind":"email","label":"Email","save_as":"email"},
           {"id":"id","kind":"text","label":"Id","trait":"user_id"}
         ]}}
        """.trimIndent(),
    )

    private val responses = mapOf<String, Any?>("age" to 31, "likes" to "Coats,Shoes", "email" to "a@b.co", "id" to "someone-else")

    @Test
    fun keepsAnAddressAndOnlyTheDeclaredUnreservedTraits() {
        val (addresses, traits) = formKeeps(inApp(listOf("age", "likes", "user_id")), responses)
        assertEquals(mapOf("email" to "a@b.co"), addresses)
        assertEquals(mapOf<String, Any?>("age" to 31, "likes" to "Coats,Shoes"), traits)
    }

    @Test
    fun setsNothingTheMessageDidNotDeclare() {
        assertEquals(mapOf<String, Any?>("age" to 31), formKeeps(inApp(listOf("age")), responses).second)
        assertEquals(emptyMap<String, Any?>(), formKeeps(inApp(listOf("age")), mapOf("age" to "")).second)
        assertEquals(emptyMap<String, String>() to emptyMap<String, Any?>(), formKeeps(null, responses))
    }
}
