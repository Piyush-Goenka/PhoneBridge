package com.piyush.phonebridge.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrPayloadTest {

    private val valid = """
        {"v":1,"host":"Piyushs-MacBook.local","port":52735,
         "token":"abc123","fp":"deadbeef"}
    """.trimIndent()

    @Test
    fun parsesValidPayload() {
        val p = QrPayload.parse(valid)!!
        assertEquals("Piyushs-MacBook.local", p.host)
        assertEquals(52735, p.port)
        assertEquals("abc123", p.token)
        assertEquals("deadbeef", p.fingerprint)
    }

    @Test
    fun rejectsWrongVersion() {
        assertNull(QrPayload.parse(valid.replace("\"v\":1", "\"v\":2")))
    }

    @Test
    fun rejectsMissingField() {
        assertNull(QrPayload.parse("""{"v":1,"host":"x","port":1,"token":"t"}"""))
    }

    @Test
    fun rejectsGarbage() {
        assertNull(QrPayload.parse("not json at all"))
        assertNull(QrPayload.parse(""))
    }
}
