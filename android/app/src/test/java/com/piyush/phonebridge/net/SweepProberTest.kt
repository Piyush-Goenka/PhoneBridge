package com.piyush.phonebridge.net

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.security.MessageDigest

class SweepProberTest {

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
    fun findsHostWithPinnedCertificate() = runBlocking {
        val prober = SweepProber(fingerprint)
        assertEquals(
            server.hostName,
            prober.findMac(listOf(server.hostName), server.port))
    }

    @Test
    fun rejectsHostWithWrongCertificate() = runBlocking {
        val prober = SweepProber("ab".repeat(32))
        assertNull(prober.findMac(listOf(server.hostName), server.port))
    }

    @Test
    fun skipsDeadHostsAndFindsTheMac() = runBlocking {
        val prober = SweepProber(fingerprint)
        assertEquals(
            server.hostName,
            prober.findMac(listOf("203.0.113.1", server.hostName), server.port))
    }

    @Test
    fun nothingListeningMeansNull() = runBlocking {
        val port = server.port
        server.shutdown()
        val prober = SweepProber(fingerprint)
        assertNull(prober.findMac(listOf("127.0.0.1"), port))
    }
}
