package com.piyush.phonebridge.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrPayloadTest {

    private val token = "abcDEF012345_-6789ghijklmnopqrstuvwxyzABCDE"
    private val fp = "a".repeat(64)
    private val valid = """
        {"v":1,"host":"Piyushs-MacBook.local","port":52735,
         "token":"$token","fp":"$fp"}
    """.trimIndent()

    @Test
    fun parsesValidPayload() {
        val p = QrPayload.parse(valid)!!
        assertEquals("Piyushs-MacBook.local", p.host)
        assertEquals(52735, p.port)
        assertEquals(token, p.token)
        assertEquals(fp, p.fingerprint)
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

    @Test
    fun rejectsEmptyHost() {
        assertNull(QrPayload.parse(valid.replace("\"Piyushs-MacBook.local\"", "\"\"")))
    }

    @Test
    fun rejectsOutOfRangePort() {
        assertNull(QrPayload.parse(valid.replace("52735", "70000")))
        assertNull(QrPayload.parse(valid.replace("52735", "0")))
    }

    @Test
    fun rejectsMalformedToken() {
        assertNull(QrPayload.parse(valid.replace(token, "short")))
        assertNull(QrPayload.parse(valid.replace(token, "has spaces !!")))
    }

    @Test
    fun rejectsMalformedFingerprint() {
        assertNull(QrPayload.parse(valid.replace(fp, "deadbeef")))
        assertNull(QrPayload.parse(valid.replace(fp, "z".repeat(64))))
    }
}
