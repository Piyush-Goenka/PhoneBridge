package com.piyush.phonebridge.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket

// Finds the Mac on the local subnet by knocking on its port and verifying
// the pinned certificate: a completed handshake against the pinned trust
// manager is cryptographic proof the host is the paired Mac. Cheap TCP
// connects weed out dead addresses before any TLS work happens.
class SweepProber(
    fingerprintHex: String,
    private val connectTimeoutMs: Int = 300,
    private val handshakeTimeoutMs: Int = 2_000,
    private val concurrency: Int = 64,
) {
    private val socketFactory =
        PinnedTls.socketFactory(PinnedTls.trustManager(fingerprintHex))

    suspend fun findMac(candidates: List<String>, port: Int): String? {
        for (chunk in candidates.chunked(concurrency)) {
            val verified = coroutineScope {
                chunk.map { ip ->
                    async(Dispatchers.IO) { if (probe(ip, port)) ip else null }
                }.awaitAll()
            }
            verified.firstOrNull { it != null }?.let { return it }
        }
        return null
    }

    private fun probe(ip: String, port: Int): Boolean = try {
        Socket().use { tcp ->
            tcp.connect(InetSocketAddress(ip, port), connectTimeoutMs)
            (socketFactory.createSocket(tcp, ip, port, true) as SSLSocket).use { tls ->
                tls.soTimeout = handshakeTimeoutMs
                tls.startHandshake()
                true
            }
        }
    } catch (e: Exception) {
        false
    }
}
