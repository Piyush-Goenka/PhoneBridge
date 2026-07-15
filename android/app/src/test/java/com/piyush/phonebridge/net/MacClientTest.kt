package com.piyush.phonebridge.net

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.security.MessageDigest

class MacClientTest {

    private lateinit var server: MockWebServer
    private lateinit var fingerprint: String

    @Before
    fun setUp() {
        val cert = HeldCertificate.Builder()
            .addSubjectAlternativeName("localhost")
            .build()
        fingerprint = MessageDigest.getInstance("SHA-256")
            .digest(cert.certificate.encoded)
            .joinToString("") { "%02x".format(it) }
        val certs = HandshakeCertificates.Builder()
            .heldCertificate(cert)
            .build()
        server = MockWebServer()
        server.useHttps(certs.sslSocketFactory(), false)
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun acceptsPinnedCertAndParsesNeedIcon() {
        server.enqueue(MockResponse().setBody("""{"needIcon":true}"""))
        val client = MacClient("tok", fingerprint)
        val result = client.postNotify(server.hostName, server.port, "{}")
        assertEquals(MacClient.SendResult.Ok(needIcon = true), result)
        val recorded = server.takeRequest()
        assertEquals("Bearer tok", recorded.getHeader("Authorization"))
        assertEquals("/notify", recorded.path)
    }

    @Test
    fun needIconFalseParsed() {
        server.enqueue(MockResponse().setBody("""{"needIcon":false}"""))
        val client = MacClient("tok", fingerprint)
        assertEquals(
            MacClient.SendResult.Ok(needIcon = false),
            client.postNotify(server.hostName, server.port, "{}"))
    }

    @Test
    fun rejectsWrongFingerprint() {
        server.enqueue(MockResponse().setBody("{}"))
        val client = MacClient("tok", "ab".repeat(32))
        val result = client.postNotify(server.hostName, server.port, "{}")
        assertTrue(result is MacClient.SendResult.Failed)
        assertEquals(
            "certificate fingerprint mismatch, re-pair needed",
            (result as MacClient.SendResult.Failed).reason)
    }

    @Test
    fun http401IsAuthFailed() {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"unauthorized"}"""))
        val client = MacClient("wrong", fingerprint)
        assertEquals(
            MacClient.SendResult.AuthFailed,
            client.postNotify(server.hostName, server.port, "{}"))
    }

    @Test
    fun connectionRefusedIsFailed() {
        val port = server.port
        server.shutdown()
        val client = MacClient("tok", fingerprint)
        assertTrue(client.postNotify("localhost", port, "{}") is MacClient.SendResult.Failed)
    }

    @Test
    fun dismissHitsDismissPath() {
        server.enqueue(MockResponse().setBody("{}"))
        val client = MacClient("tok", fingerprint)
        client.postDismiss(server.hostName, server.port, """{"key":"k"}""")
        assertEquals("/dismiss", server.takeRequest().path)
    }
}
