package com.piyush.phonebridge.filter

import com.piyush.phonebridge.model.RelayNotification
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DedupCacheTest {

    private fun notif(pkg: String = "com.whatsapp", title: String = "Alice", text: String = "hi") =
        RelayNotification(
            key = "k", pkg = pkg, appName = pkg, title = title, text = text,
            postedAt = 0L, isOngoing = false, isGroupSummary = false, category = null)

    @Test
    fun firstSightIsNotDuplicate() {
        val cache = DedupCache()
        assertFalse(cache.isDuplicate(notif(), now = 1_000L))
    }

    @Test
    fun samePostWithinWindowIsDuplicate() {
        // WhatsApp re-posting the identical notification moments later.
        val cache = DedupCache(windowMillis = 30_000L)
        assertFalse(cache.isDuplicate(notif(), now = 1_000L))
        assertTrue(cache.isDuplicate(notif(), now = 2_000L))
    }

    @Test
    fun samePostAfterWindowIsFresh() {
        val cache = DedupCache(windowMillis = 30_000L)
        assertFalse(cache.isDuplicate(notif(), now = 1_000L))
        assertFalse(cache.isDuplicate(notif(), now = 40_000L))
    }

    @Test
    fun differentTextIsNotDuplicate() {
        val cache = DedupCache()
        assertFalse(cache.isDuplicate(notif(text = "hi"), now = 1_000L))
        assertFalse(cache.isDuplicate(notif(text = "hi again"), now = 2_000L))
    }

    @Test
    fun differentPackageSameTextIsNotDuplicate() {
        val cache = DedupCache()
        assertFalse(cache.isDuplicate(notif(pkg = "a", text = "hi"), now = 1_000L))
        assertFalse(cache.isDuplicate(notif(pkg = "b", text = "hi"), now = 2_000L))
    }
}
