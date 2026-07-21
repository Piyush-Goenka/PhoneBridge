package com.piyush.phonebridge.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import com.piyush.phonebridge.pairing.PairingStore
import java.net.Inet4Address

// The self-healing location layer. Trust (token + fingerprint) comes from
// the one-time QR scan and never expires; the Mac's address is only a
// cache, rebuilt here when it goes stale: mDNS first (one multicast
// query), then a fingerprint-verified subnet sweep for routers that block
// mDNS. Runs only inside a delivery attempt, never in the background.
class HostResolver(private val context: Context) {

    companion object {
        // Shared across calls: a sleeping Mac must cost at most one sweep
        // per cooldown window, not one per notification.
        @Volatile
        internal var lastSweepFailureAt = 0L
    }

    suspend fun rediscover(
        store: PairingStore,
        now: Long = System.currentTimeMillis(),
    ): Pair<String, Int>? {
        val fingerprint = store.fingerprint ?: return null

        MacDiscovery(context).discover()?.let { (host, port) ->
            // mDNS is unauthenticated multicast: anyone on the LAN can answer,
            // and a poisoned answer would otherwise overwrite the cached host
            // AND port, breaking the sweep too. Only trust it after the pinned
            // certificate check passes, exactly like the sweep path below.
            if (SweepProber(fingerprint).findMac(listOf(host), port) != null) {
                Log.d("PhoneBridge", "rediscover: mDNS verified $host:$port")
                store.host = host
                store.port = port
                lastSweepFailureAt = 0L
                return host to port
            }
            Log.d("PhoneBridge", "rediscover: mDNS $host:$port failed pin check, ignoring")
        }

        if (!SweepPlan.shouldSweep(now, lastSweepFailureAt)) {
            Log.d("PhoneBridge", "rediscover: sweep on cooldown")
            return null
        }
        val (ownIp, prefix) = wifiIpv4() ?: run {
            Log.d("PhoneBridge", "rediscover: not on Wi-Fi, no sweep")
            return null
        }
        if (!SweepPlan.isPrivateIpv4(ownIp)) return null
        val candidates = SweepPlan.candidates(ownIp, prefix, store.host)
        if (candidates.isEmpty()) return null

        Log.d("PhoneBridge", "rediscover: sweeping ${candidates.size} hosts on port ${store.port}")
        val found = SweepProber(fingerprint).findMac(candidates, store.port)
        return if (found != null) {
            Log.d("PhoneBridge", "rediscover: sweep found Mac at $found")
            store.host = found
            lastSweepFailureAt = 0L
            found to store.port
        } else {
            Log.d("PhoneBridge", "rediscover: sweep found nothing, cooldown armed")
            lastSweepFailureAt = now
            null
        }
    }

    // The phone's IPv4 and prefix length on the active Wi-Fi network,
    // or null when the active network is not Wi-Fi.
    private fun wifiIpv4(): Pair<String, Int>? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return null
        val caps = cm.getNetworkCapabilities(network) ?: return null
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return null
        val link = cm.getLinkProperties(network) ?: return null
        val ipv4 = link.linkAddresses.firstOrNull { it.address is Inet4Address }
            ?: return null
        val host = ipv4.address.hostAddress ?: return null
        return host to ipv4.prefixLength
    }
}
