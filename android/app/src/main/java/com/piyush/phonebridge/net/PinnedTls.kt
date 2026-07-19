package com.piyush.phonebridge.net

import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

// TLS primitives pinned to the Mac's certificate. Trust is exactly one
// check: SHA-256 of the leaf DER equals the fingerprint from the QR.
object PinnedTls {

    fun trustManager(fingerprintHex: String): X509TrustManager {
        val pin = fingerprintHex.lowercase()
        return object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
                throw CertificateException("client certificates not supported")
            }

            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val leaf = chain.firstOrNull()
                    ?: throw CertificateException("empty certificate chain")
                val fp = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
                    .joinToString("") { "%02x".format(it) }
                if (fp != pin) {
                    throw CertificateException("certificate fingerprint mismatch, re-pair needed")
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
    }

    fun socketFactory(trustManager: X509TrustManager): SSLSocketFactory =
        SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(trustManager), null)
        }.socketFactory
}
