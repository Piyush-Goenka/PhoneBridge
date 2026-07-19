package com.piyush.phonebridge.net

// Pure IPv4 math for the subnet sweep: which addresses to probe, in what
// order, and whether sweeping is allowed at all. No Android imports so it
// runs under plain JVM tests.
object SweepPlan {

    const val COOLDOWN_MS = 90_000L

    // /23 (510 hosts) is the widest subnet worth sweeping; anything wider
    // is a corporate network where a sweep is rude and futile.
    private const val MIN_PREFIX = 23
    private const val MAX_PREFIX = 30

    fun shouldSweep(now: Long, lastFailureAt: Long): Boolean =
        now - lastFailureAt >= COOLDOWN_MS

    fun isPrivateIpv4(ip: String): Boolean {
        val value = parse(ip) ?: return false
        val a = value ushr 24 and 0xff
        val b = value ushr 16 and 0xff
        return a == 10 || (a == 172 && b in 16..31) || (a == 192 && b == 168)
    }

    // Every host address in ownIp's subnet except self, network, and
    // broadcast; cached host first because routers often re-issue the same
    // address. Empty when the subnet is too wide or the input is not IPv4.
    fun candidates(ownIp: String, prefixLength: Int, cachedHost: String?): List<String> {
        if (prefixLength !in MIN_PREFIX..MAX_PREFIX) return emptyList()
        val own = parse(ownIp) ?: return emptyList()
        val mask = -1 shl (32 - prefixLength)
        val network = own and mask
        val broadcast = network or mask.inv()
        val hosts = ((network + 1) until broadcast)
            .filter { it != own }
            .map { format(it) }
        val cached = cachedHost?.takeIf { it in hosts } ?: return hosts
        return listOf(cached) + hosts.filter { it != cached }
    }

    private fun parse(ip: String): Int? {
        val parts = ip.split(".")
        if (parts.size != 4) return null
        var value = 0
        for (part in parts) {
            val octet = part.toIntOrNull() ?: return null
            if (octet !in 0..255) return null
            value = (value shl 8) or octet
        }
        return value
    }

    private fun format(ip: Int): String =
        "${ip ushr 24 and 0xff}.${ip ushr 16 and 0xff}.${ip ushr 8 and 0xff}.${ip and 0xff}"
}
