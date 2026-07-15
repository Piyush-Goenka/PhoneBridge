package com.piyush.phonebridge.filter

import com.piyush.phonebridge.model.RelayNotification

class DedupCache(private val windowMillis: Long = 30_000L) {

    private val seen = HashMap<String, Long>()

    @Synchronized
    fun isDuplicate(n: RelayNotification, now: Long): Boolean {
        seen.entries.removeIf { now - it.value > windowMillis }
        val fingerprint = "${n.pkg}|${n.title}|${n.text}"
        val duplicate = seen.containsKey(fingerprint)
        seen[fingerprint] = now
        return duplicate
    }
}
