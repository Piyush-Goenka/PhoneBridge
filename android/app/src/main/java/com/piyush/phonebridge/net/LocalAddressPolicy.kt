package com.piyush.phonebridge.net

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

// Pairing must terminate on the local network. A certificate pin proves that
// the endpoint owns the QR certificate, but the QR itself is untrusted and
// must not be able to redirect notifications to an Internet host.
object LocalAddressPolicy {

    fun resolveAllowed(host: String): List<String> = try {
        InetAddress.getAllByName(host)
            .filter(::isAllowed)
            .mapNotNull { it.hostAddress }
            .distinct()
    } catch (_: Exception) {
        emptyList()
    }

    internal fun isAllowed(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress) return false
        if (address.isLinkLocalAddress) return true
        return when (address) {
            is Inet4Address -> isAllowedIpv4(address.address)
            is Inet6Address -> {
                val first = address.address.first().toInt() and 0xff
                first and 0xfe == 0xfc // IPv6 unique-local fc00::/7
            }
            else -> false
        }
    }

    private fun isAllowedIpv4(bytes: ByteArray): Boolean {
        if (bytes.size != 4) return false
        val a = bytes[0].toInt() and 0xff
        val b = bytes[1].toInt() and 0xff
        return a == 10 ||
            (a == 172 && b in 16..31) ||
            (a == 192 && b == 168) ||
            (a == 169 && b == 254) ||
            (a == 100 && b in 64..127) // private VPN / CGNAT range
    }
}
